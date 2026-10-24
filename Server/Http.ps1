#Requires -Version 5.1
# =============================================================================
# Keystone local HTTP server: transport, session bootstrap, security gate.
# Same design as ARC lib/server/Http.ps1 (TechStack: PowerShell 5.1 + TcpListener
# on 127.0.0.1, no HTTP.sys URL reservation).
#
#   * Sequential request handling with hard deadlines; long work runs as
#     background jobs (Server/Jobs.ps1) so no request blocks the UI.
#   * A connection that sends nothing within 2 s is closed (browser preconnects).
#   * Headers within 5 s, capped at 32 KB; bodies capped at 1 MB.
#   * Transfer-Encoding and duplicate Content-Length are rejected.
#   * Session: one-time launch nonce in the URL fragment (120 s) ->
#     HttpOnly; SameSite=Strict cookie. Every /api call also needs
#     X-Keystone-Client, a loopback Host and (if sent) a loopback Origin.
#   * On Windows, connections from another user's processes are refused.
# =============================================================================

$script:KeystoneHttp = @{
    Port = 0; Listener = $null; Stream = $null; Client = $null; Responded = $false
    Nonce = $null; NonceExpires = [datetime]::MinValue
    SessionToken = $null; ClientSecret = $null; StopRequested = $false
    UiRoot = ''; Manifest = @('index.html','app.js','app.css')
    Csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    PeerCheck = 'unknown'
    MaxBody = 1048576
}

function New-KeystoneRandomToken {
    param([int]$Bytes = 32)
    $b = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_'))
}

function Test-KeystoneStringsEqual {
    # Constant-time comparison of two strings.
    param([string]$A,[string]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    $x = [Text.Encoding]::UTF8.GetBytes($A); $y = [Text.Encoding]::UTF8.GetBytes($B)
    if ($x.Length -ne $y.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $x.Length; $i++) { $diff = $diff -bor ($x[$i] -bxor $y[$i]) }
    return ($diff -eq 0)
}

function New-KeystoneLaunchNonce {
    $script:KeystoneHttp.Nonce = New-KeystoneRandomToken
    $script:KeystoneHttp.NonceExpires = (Get-Date).AddSeconds(120)
    return $script:KeystoneHttp.Nonce
}

function Get-KeystoneLaunchUrl { return ('http://127.0.0.1:{0}/#k={1}' -f $script:KeystoneHttp.Port, $script:KeystoneHttp.Nonce) }

function Use-KeystoneLaunchNonce {
    # One shot: a correct, unexpired nonce mints the session token and is burned.
    param([string]$Nonce)
    if ([string]::IsNullOrEmpty($script:KeystoneHttp.Nonce)) { return $null }
    if ((Get-Date) -gt $script:KeystoneHttp.NonceExpires) { $script:KeystoneHttp.Nonce = $null; return $null }
    if (-not (Test-KeystoneStringsEqual $Nonce $script:KeystoneHttp.Nonce)) { return $null }
    $script:KeystoneHttp.Nonce = $null
    $script:KeystoneHttp.SessionToken = New-KeystoneRandomToken
    # Second secret, returned once in the response body and kept by the page in
    # sessionStorage (per origin, so per port). Browsers send localhost cookies to
    # every port, so the cookie alone could be replayed by another local server.
    $script:KeystoneHttp.ClientSecret = New-KeystoneRandomToken
    return $script:KeystoneHttp.SessionToken
}

function Test-KeystoneSessionCookie {
    param($Req)
    $tok = $Req.Cookies['keystone_session']
    if ([string]::IsNullOrEmpty($tok) -or [string]::IsNullOrEmpty($script:KeystoneHttp.SessionToken)) { return $false }
    return (Test-KeystoneStringsEqual $tok $script:KeystoneHttp.SessionToken)
}

# ---------------------------------------------------------------------------
# Peer ownership (Windows): refuse sockets owned by another user's process.
# ---------------------------------------------------------------------------
function Initialize-KeystonePeerCheck {
    if ($script:KeystoneHttp.PeerCheck -ne 'unknown') { return ($script:KeystoneHttp.PeerCheck -eq 'enabled') }
    if ($env:OS -ne 'Windows_NT') { $script:KeystoneHttp.PeerCheck = 'disabled'; return $false }
    if ('KeystonePeer' -as [type]) { $script:KeystoneHttp.PeerCheck = 'enabled'; return $true }
    $src = @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class KeystonePeer {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tableClass, uint reserved);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential)]
    struct MIB_TCPROW_OWNER_PID { public uint state; public uint localAddr; public uint localPort; public uint remoteAddr; public uint remotePort; public uint owningPid; }
    static int Port(uint networkOrderLow16) { return (int)(((networkOrderLow16 & 0xFF) << 8) | ((networkOrderLow16 >> 8) & 0xFF)); }
    public static int GetOwningPid(int peerLocalPort, int ourPort) {
        int len = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref len, false, 2, 5, 0);
        if (len <= 0) return -1;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            if (GetExtendedTcpTable(buf, ref len, false, 2, 5, 0) != 0) return -1;
            int n = Marshal.ReadInt32(buf);
            IntPtr row = new IntPtr(buf.ToInt64() + 4);
            int size = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
            for (int i = 0; i < n; i++) {
                MIB_TCPROW_OWNER_PID r = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(row, typeof(MIB_TCPROW_OWNER_PID));
                if (Port(r.localPort) == peerLocalPort && Port(r.remotePort) == ourPort) return (int)r.owningPid;
                row = new IntPtr(row.ToInt64() + size);
            }
            return -1;
        } finally { Marshal.FreeHGlobal(buf); }
    }
    public static string GetProcessUserSid(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            IntPtr tok;
            if (!OpenProcessToken(h, 0x0008, out tok)) return null;
            try { using (WindowsIdentity wi = new WindowsIdentity(tok)) { return wi.User.Value; } }
            finally { CloseHandle(tok); }
        } finally { CloseHandle(h); }
    }
}
'@
    try {
        Add-Type -TypeDefinition $src -ErrorAction Stop
        $script:KeystoneHttp.PeerCheck = 'enabled'
        return $true
    } catch {
        Write-KeystoneLog -Level WARN -Message 'Peer ownership check unavailable (for example Constrained Language); loopback checks still apply.'
        $script:KeystoneHttp.PeerCheck = 'disabled'
        return $false
    }
}

function Test-KeystonePeerIsCurrentUser {
    # $true same user, $false another user (refuse), $null undetermined (allowed, loopback-only anyway)
    param([System.Net.Sockets.TcpClient]$Client)
    if (-not (Initialize-KeystonePeerCheck)) { return $null }
    try {
        $peerPort = ([Net.IPEndPoint]$Client.Client.RemoteEndPoint).Port
        $ownerPid = [KeystonePeer]::GetOwningPid($peerPort, $script:KeystoneHttp.Port)
        if ($ownerPid -le 0) { return $null }
        $sid = [KeystonePeer]::GetProcessUserSid($ownerPid)
        # A process we cannot open is, for a normal user, another account's process.
        if ([string]::IsNullOrEmpty($sid)) { return $false }
        return ($sid -eq [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Responses
# ---------------------------------------------------------------------------
function Get-KeystoneHttpReason {
    param([int]$Status)
    switch ($Status) {
        200 { 'OK' } 202 { 'Accepted' } 204 { 'No Content' } 400 { 'Bad Request' } 401 { 'Unauthorized' } 403 { 'Forbidden' }
        404 { 'Not Found' } 405 { 'Method Not Allowed' } 408 { 'Request Timeout' } 409 { 'Conflict' } 415 { 'Unsupported Media Type' } 413 { 'Payload Too Large' }
        429 { 'Too Many Requests' } 500 { 'Internal Server Error' } 502 { 'Bad Gateway' } default { 'Error' }
    }
}

function Get-KeystoneSecurityHeaders {
    return @(
        'Cache-Control: no-store',
        'X-Content-Type-Options: nosniff',
        'X-Frame-Options: DENY',
        'Referrer-Policy: no-referrer',
        'Cross-Origin-Resource-Policy: same-origin',
        'Cross-Origin-Opener-Policy: same-origin',
        'Permissions-Policy: camera=(), microphone=(), geolocation=()',
        ('Content-Security-Policy: ' + $script:KeystoneHttp.Csp)
    )
}

function Send-KeystoneHttpBytes {
    param([int]$Status,[string]$ContentType,[byte[]]$Bytes,[string[]]$ExtraHeaders = @())
    $stream = $script:KeystoneHttp.Stream
    if ($null -eq $stream) { return }
    $lines = @("HTTP/1.1 $Status $(Get-KeystoneHttpReason $Status)", "Content-Type: $ContentType", "Content-Length: $($Bytes.Length)", 'Connection: close') + (Get-KeystoneSecurityHeaders) + $ExtraHeaders
    $head = [Text.Encoding]::ASCII.GetBytes(($lines -join "`r`n") + "`r`n`r`n")
    $stream.Write($head,0,$head.Length)
    if ($Bytes.Length -gt 0) { $stream.Write($Bytes,0,$Bytes.Length) }
    $stream.Flush()
    $script:KeystoneHttp.Responded = $true
}

function Send-KeystoneJson {
    param([int]$Status = 200,$Object,[string[]]$ExtraHeaders = @())
    $json = ($Object | ConvertTo-Json -Depth 14 -Compress)
    if ($null -eq $json) { $json = '{}' }
    Send-KeystoneHttpBytes -Status $Status -ContentType 'application/json; charset=utf-8' -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) -ExtraHeaders $ExtraHeaders
}

function Send-KeystoneError {
    param([int]$Status,[string]$Code,[string]$Message = '')
    Send-KeystoneJson -Status $Status -Object @{ error = $Code; message = $Message }
}

# ---------------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------------
function Read-KeystoneHttpRequest {
    param([System.Net.Sockets.TcpClient]$Client)
    $sock = $Client.Client
    if (-not $sock.Poll(2000000,[Net.Sockets.SelectMode]::SelectRead)) { return $null }   # nothing sent in 2 s
    if ($sock.Available -eq 0) { return $null }                                            # closed
    $Client.ReceiveTimeout = 5000
    $Client.SendTimeout = 30000
    $stream = $Client.GetStream()
    $script:KeystoneHttp.Stream = $stream
    $buf = New-Object System.Collections.Generic.List[byte]
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        if ($buf.Count -gt 32768) { Send-KeystoneError 413 'HEADERS_TOO_LARGE' 'Request headers too large.'; return $null }
        if ($clock.ElapsedMilliseconds -gt 5000) { Send-KeystoneError 408 'TIMEOUT' 'Request headers too slow.'; return $null }
        $b = $stream.ReadByte()
        if ($b -lt 0) { return $null }
        $buf.Add([byte]$b)
        $n = $buf.Count
        if ($n -ge 4 -and $buf[$n-4] -eq 13 -and $buf[$n-3] -eq 10 -and $buf[$n-2] -eq 13 -and $buf[$n-1] -eq 10) { $headerEnd = $n }
    }
    $lines = [Text.Encoding]::ASCII.GetString($buf.ToArray(),0,$headerEnd - 4) -split "`r`n"
    if ($lines.Count -lt 1 -or $lines[0] -notmatch '^([A-Z]{3,7}) (\S+) HTTP/1\.[01]$') { Send-KeystoneError 400 'BAD_REQUEST' 'Malformed request line.'; return $null }
    $method = $Matches[1]; $target = $Matches[2]
    $headers = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $contentLength = -1; $clCount = 0
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line -notmatch '^([^:\s]+):\s*(.*)$') { Send-KeystoneError 400 'BAD_REQUEST' 'Malformed header.'; return $null }
        $name = $Matches[1]; $value = $Matches[2].Trim()
        if ($name -eq 'Content-Length') {
            $clCount++
            if ($value -notmatch '^\d{1,9}$') { Send-KeystoneError 400 'BAD_REQUEST' 'Bad Content-Length.'; return $null }
            $contentLength = [int]$value
        }
        if ($name -eq 'Transfer-Encoding') { Send-KeystoneError 400 'BAD_REQUEST' 'Transfer-Encoding is not supported.'; return $null }
        if ($headers.ContainsKey($name)) { $headers[$name] = $headers[$name] + ', ' + $value } else { $headers[$name] = $value }
    }
    if ($clCount -gt 1) { Send-KeystoneError 400 'BAD_REQUEST' 'Duplicate Content-Length.'; return $null }
    if ($contentLength -gt $script:KeystoneHttp.MaxBody) { Send-KeystoneError 413 'BODY_TOO_LARGE' 'Request body too large.'; return $null }
    $body = New-Object byte[] 0
    if ($contentLength -gt 0) {
        $body = New-Object byte[] $contentLength
        $read = 0
        while ($read -lt $contentLength) {
            if ($clock.ElapsedMilliseconds -gt 15000) { Send-KeystoneError 408 'TIMEOUT' 'Request body too slow.'; return $null }
            $c = $stream.Read($body,$read,$contentLength - $read)
            if ($c -le 0) { break }
            $read += $c
        }
        if ($read -ne $contentLength) { Send-KeystoneError 400 'BAD_REQUEST' 'Incomplete body.'; return $null }
    }
    $path = $target; $query = ''
    $qi = $target.IndexOf('?'); if ($qi -ge 0) { $path = $target.Substring(0,$qi); $query = $target.Substring($qi + 1) }
    if ($path -notmatch '^/[A-Za-z0-9._~/\-]*$' -or $path -match '\.\.') { Send-KeystoneError 400 'BAD_REQUEST' 'Bad path.'; return $null }
    $cookies = @{}
    if ($headers.ContainsKey('Cookie')) {
        foreach ($part in ($headers['Cookie'] -split ';')) {
            $kv = $part.Trim(); $eq = $kv.IndexOf('=')
            if ($eq -gt 0) { $cookies[$kv.Substring(0,$eq)] = $kv.Substring($eq + 1) }
        }
    }
    return @{ Method = $method; Path = $path; Query = $query; Headers = $headers; Cookies = $cookies; BodyBytes = $body; Json = $null }
}

function Get-KeystoneQueryValue {
    param([string]$Query,[string]$Name)
    foreach ($kv in ($Query -split '&')) {
        $eq = $kv.IndexOf('=')
        if ($eq -gt 0 -and $kv.Substring(0,$eq) -eq $Name) { return [Uri]::UnescapeDataString($kv.Substring($eq + 1).Replace('+',' ')) }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Gate and dispatch
# ---------------------------------------------------------------------------
function Test-KeystoneLoopbackRequest {
    param($Req)
    $port = $script:KeystoneHttp.Port
    $h = ''; if ($Req.Headers.ContainsKey('Host')) { $h = $Req.Headers['Host'] }
    if ($h -notin @("127.0.0.1:$port","localhost:$port")) { return $false }
    if ($Req.Headers.ContainsKey('Origin')) {
        if ($Req.Headers['Origin'] -notin @("http://127.0.0.1:$port","http://localhost:$port")) { return $false }
    }
    return $true
}

function Invoke-KeystoneServerRequest {
    param($Req)
    $script:KeystoneHttp.Responded = $false
    if (-not (Test-KeystoneLoopbackRequest $Req)) { Send-KeystoneError 400 'BAD_ORIGIN' 'Invalid local origin.'; return }
    if (-not $Req.Path.StartsWith('/api/')) {
        if ($Req.Method -ne 'GET') { Send-KeystoneError 405 'METHOD' 'Method not allowed.'; return }
        Send-KeystoneStaticFile -Path $Req.Path
        return
    }
    if ($Req.BodyBytes.Length -gt 0) {
        $ct = ''; if ($Req.Headers.ContainsKey('Content-Type')) { $ct = $Req.Headers['Content-Type'] }
        if ($ct -notmatch '^application/json(\s*;|$)') { Send-KeystoneError 415 'BAD_REQUEST' 'Expected application/json.'; return }
        try { $Req.Json = [Text.Encoding]::UTF8.GetString($Req.BodyBytes) | ConvertFrom-Json -ErrorAction Stop }
        catch { Send-KeystoneError 400 'BAD_REQUEST' 'Body is not valid JSON.'; return }
    }
    if ($Req.Path -eq '/api/health' -and $Req.Method -eq 'GET') {
        $sent = ''; if ($Req.Headers.ContainsKey('X-Keystone-Client')) { $sent = $Req.Headers['X-Keystone-Client'] }
        Send-KeystoneJson -Object @{ ok = $true; app = 'keystone'; session = ((Test-KeystoneSessionCookie $Req) -and (Test-KeystoneStringsEqual $sent $script:KeystoneHttp.ClientSecret)) }
        return
    }
    if ($Req.Path -eq '/api/session' -and $Req.Method -eq 'POST') {
        $nonce = ''; try { $nonce = [string]$Req.Json.nonce } catch { }
        $tok = Use-KeystoneLaunchNonce -Nonce $nonce
        if ($null -eq $tok) {
            Write-KeystoneLog -Level WARN -Message 'Session bootstrap refused (bad or expired launch link).'
            Send-KeystoneError 401 'SESSION' 'This launch link has expired. Use the link in the Keystone window, or restart Keystone.'
            return
        }
        Send-KeystoneJson -Object @{ ok = $true; client = $script:KeystoneHttp.ClientSecret } -ExtraHeaders @("Set-Cookie: keystone_session=$tok; HttpOnly; SameSite=Strict; Path=/")
        return
    }
    $client = ''; if ($Req.Headers.ContainsKey('X-Keystone-Client')) { $client = $Req.Headers['X-Keystone-Client'] }
    if (-not (Test-KeystoneStringsEqual $client $script:KeystoneHttp.ClientSecret)) { Send-KeystoneError 401 'SESSION' 'Session ended. Use the link in the Keystone window (press L there for a new one).'; return }
    if (-not (Test-KeystoneSessionCookie $Req)) { Send-KeystoneError 401 'SESSION' 'Session ended. Use the link in the Keystone window, or restart Keystone.'; return }
    Invoke-KeystoneRoute -Req $Req
}

function Send-KeystoneStaticFile {
    param([string]$Path)
    $name = if ($Path -eq '/') { 'index.html' } else { $Path.TrimStart('/') }
    if ($name -notin $script:KeystoneHttp.Manifest) { Send-KeystoneError 404 'NOT_FOUND' 'Not found.'; return }
    $file = Join-Path $script:KeystoneHttp.UiRoot $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-KeystoneError 404 'NOT_FOUND' 'Not found.'; return }
    $mime = switch ([IO.Path]::GetExtension($name).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' } '.js' { 'application/javascript; charset=utf-8' } '.css' { 'text/css; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' } '.svg' { 'image/svg+xml' } '.png' { 'image/png' } '.ico' { 'image/x-icon' }
        '.woff2' { 'font/woff2' } '.wasm' { 'application/wasm' } default { 'application/octet-stream' }
    }
    Send-KeystoneHttpBytes -Status 200 -ContentType $mime -Bytes ([IO.File]::ReadAllBytes($file))
}

function Initialize-KeystoneUiManifest {
    # ui/dist/manifest.json (future built UI) lists servable files; otherwise the
    # current web/ trio. Only listed files are ever served.
    param([Parameter(Mandatory)][string]$UiRoot)
    $script:KeystoneHttp.UiRoot = $UiRoot
    $m = Join-Path $UiRoot 'manifest.json'
    if (Test-Path -LiteralPath $m) {
        $list = @((Get-Content -LiteralPath $m -Raw | ConvertFrom-Json) | ForEach-Object { [string]$_ })
        $script:KeystoneHttp.Manifest = @($list | Where-Object { $_ -match '^[A-Za-z0-9._\-]+(/[A-Za-z0-9._\-]+)*$' -and $_ -notmatch '\.\.' })
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
function Start-KeystoneHttpServer {
    param(
        [int]$PreferredPort = 8769,
        [Parameter(Mandatory)][string]$UiRoot,
        [scriptblock]$OnReady = $null,
        [scriptblock]$OnTick = $null
    )
    Initialize-KeystoneUiManifest -UiRoot $UiRoot
    $address = [Net.IPAddress]::Parse('127.0.0.1')
    $listener = $null
    foreach ($candidate in @($PreferredPort,0)) {
        try {
            $l = [Net.Sockets.TcpListener]::new($address,[int]$candidate)
            $l.ExclusiveAddressUse = $true
            $l.Start()
            $listener = $l
            break
        } catch {
            if ($candidate -eq 0) { throw "Keystone could not bind any loopback port: $($_.Exception.Message)" }
            Write-KeystoneLog -Level WARN -Message "Port $candidate is in use; picking a free port."
        }
    }
    $script:KeystoneHttp.Listener = $listener
    $script:KeystoneHttp.Port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    [void](New-KeystoneLaunchNonce)
    $script:KeystoneHttp.StopRequested = $false
    [void](Initialize-KeystonePeerCheck)
    Write-KeystoneLog -Level INFO -Message ("Listening on http://127.0.0.1:{0}/ (peer check {1})" -f $script:KeystoneHttp.Port, $script:KeystoneHttp.PeerCheck)
    if ($OnReady) { & $OnReady (Get-KeystoneLaunchUrl) }
    try {
        while (-not $script:KeystoneHttp.StopRequested) {
            if ($OnTick) { try { & $OnTick } catch { Write-KeystoneLog -Level WARN -Message "Background update failed: $($_.Exception.Message)" } }
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue }
            $client = $null
            try {
                $client = $listener.AcceptTcpClient()
                $script:KeystoneHttp.Client = $client
                $script:KeystoneHttp.Stream = $null
                $client.NoDelay = $true
                if ((Test-KeystonePeerIsCurrentUser -Client $client) -eq $false) {
                    Write-KeystoneLog -Level WARN -Message 'Refused a connection from a process owned by another user.'
                    $script:KeystoneHttp.Stream = $client.GetStream()
                    Send-KeystoneError 403 'PEER' 'Connection refused.'
                    continue
                }
                $req = Read-KeystoneHttpRequest -Client $client
                if ($null -eq $req) { continue }
                try { Invoke-KeystoneServerRequest -Req $req }
                catch {
                    Write-KeystoneLog -Level ERROR -Message ("{0} {1}: {2}" -f $req.Method, $req.Path, $_.Exception.Message)
                    if (-not $script:KeystoneHttp.Responded) { try { Send-KeystoneError 500 'INTERNAL' 'Internal error. See the Keystone log.' } catch { } }
                }
            } catch {
                Write-KeystoneLog -Level WARN -Message ("Connection failed: {0}" -f $_.Exception.GetType().Name)
            } finally {
                if ($client) {
                    # Finish sending (FIN) before closing, so clients see a clean end of response.
                    try { $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send) } catch { }
                    try { $client.Close() } catch { }
                }
                $script:KeystoneHttp.Client = $null; $script:KeystoneHttp.Stream = $null
            }
        }
    } finally {
        try { $listener.Stop() } catch { }
        Write-KeystoneLog -Level INFO -Message 'Keystone host stopped.'
    }
}

function Stop-KeystoneHttpServer { $script:KeystoneHttp.StopRequested = $true }
