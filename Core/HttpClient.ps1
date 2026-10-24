#Requires -Version 5.1
# ============================================================
#  Core/HttpClient.ps1 - one HTTP transport for every provider call
#  - HttpWebRequest with redirects OFF: a token is never sent to a host it was
#    not meant for. Callers follow redirects themselves (archive downloads).
#  - Bounded retry for GET/HEAD only, on 429/502/503/504 and network errors,
#    honouring Retry-After (capped). Writes are never retried.
#  - Failures become coded errors: CODE|Provider API METHOD endpoint failed (HTTP n).
# ============================================================

$script:KeystoneHttpTransport = $null    # test seam: { param($Request) ... returns response }
$script:KeystoneHttpSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
$script:KeystoneHttpMaxRetryWaitMs = 10000

function Get-KeystoneProviderErrorCode {
    param([int]$Status,[hashtable]$Headers = @{})
    if ($Status -eq 0) { return 'NETWORK' }
    if ($Status -eq 401) { return 'AUTH_REJECTED' }
    if ($Status -eq 403) {
        if ($Headers['x-ratelimit-remaining'] -eq '0') { return 'RATE_LIMITED' }
        return 'FORBIDDEN'
    }
    if ($Status -eq 404) { return 'NOT_FOUND' }
    if ($Status -eq 409 -or $Status -eq 422) { return 'CONFLICT' }
    if ($Status -eq 429) { return 'RATE_LIMITED' }
    if ($Status -ge 500) { return 'SERVER_ERROR' }
    return "HTTP_$Status"
}

function Get-KeystoneRetryDelayMs {
    param([hashtable]$Headers,[int]$Attempt)
    $after = [string]$Headers['retry-after']
    $seconds = 0
    if ($after -and [int]::TryParse($after,[ref]$seconds)) { return [Math]::Min($seconds * 1000, $script:KeystoneHttpMaxRetryWaitMs) }
    return [Math]::Min(500 * [Math]::Pow(2,$Attempt - 1), $script:KeystoneHttpMaxRetryWaitMs)
}

function Invoke-KeystoneHttpOnce {
    param([pscustomobject]$Request)
    if ($script:KeystoneHttpTransport) { return (& $script:KeystoneHttpTransport $Request) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [Net.HttpWebRequest]::Create($Request.Uri)
    $req.Method = $Request.Method
    $req.AllowAutoRedirect = $false
    $req.Timeout = $Request.TimeoutSec * 1000
    $req.ReadWriteTimeout = $Request.TimeoutSec * 1000
    $req.UserAgent = 'Keystone'
    foreach ($k in $Request.Headers.Keys) {
        $v = [string]$Request.Headers[$k]
        switch ($k.ToLowerInvariant()) {
            'accept' { $req.Accept = $v }
            'content-type' { $req.ContentType = $v }
            'user-agent' { $req.UserAgent = $v }
            default { $req.Headers[$k] = $v }
        }
    }
    if ($null -ne $Request.Body) {
        $bytes = if ($Request.Body -is [byte[]]) { $Request.Body } else { [Text.Encoding]::UTF8.GetBytes([string]$Request.Body) }
        if (-not $req.ContentType) { $req.ContentType = 'application/json' }
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    } elseif ($Request.Method -in @('POST','PUT','PATCH')) {
        $req.ContentLength = 0
    }
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) {
            return [pscustomobject]@{ Status = 0; Headers = @{}; Text = ''; File = $null; NetworkError = $_.Exception.Status.ToString() }
        }
    }
    try {
        $headers = @{}
        foreach ($name in $resp.Headers.AllKeys) { $headers[$name.ToLowerInvariant()] = $resp.Headers[$name] }
        $status = [int]$resp.StatusCode
        $text = ''
        $file = $null
        $body = $resp.GetResponseStream()
        try {
            if ($Request.OutFile -and $status -ge 200 -and $status -lt 300) {
                $out = [IO.File]::Open($Request.OutFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                try { $body.CopyTo($out) } finally { $out.Dispose() }
                $file = $Request.OutFile
            } else {
                $reader = New-Object IO.StreamReader($body,[Text.Encoding]::UTF8)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } finally { if ($body) { $body.Dispose() } }
        return [pscustomobject]@{ Status = $status; Headers = $headers; Text = $text; File = $file; NetworkError = '' }
    } finally { $resp.Dispose() }
}

function Invoke-KeystoneHttpRequest {
    # Returns @{ Status; Headers; Text; File } for any HTTP status (callers decide),
    # or throws NETWORK after retries. 3xx responses are returned, not followed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        $Body = $null,
        [string]$OutFile,
        [int]$TimeoutSec = 60,
        [int]$MaxAttempts = 0
    )
    $idempotent = $Method -in @('GET','HEAD')
    if ($MaxAttempts -le 0) { $MaxAttempts = if ($idempotent) { 3 } else { 1 } }
    if (-not $idempotent) { $MaxAttempts = 1 }
    $request = [pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; OutFile = $OutFile; TimeoutSec = $TimeoutSec }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $response = Invoke-KeystoneHttpOnce -Request $request
        $retryable = ($response.Status -eq 0) -or ($response.Status -in @(429,502,503,504))
        if (-not $retryable -or $attempt -eq $MaxAttempts) { return $response }
        $wait = Get-KeystoneRetryDelayMs -Headers $response.Headers -Attempt $attempt
        Write-KeystoneLog -Level WARN -Message ("HTTP {0} {1} returned {2}; retry {3} in {4} ms" -f $Method, (Get-KeystoneSafeUrl $Uri), $response.Status, $attempt, $wait)
        & $script:KeystoneHttpSleep $wait
    }
}

function Get-KeystoneSafeUrl {
    # Scheme, host and path only: query strings can carry signed tokens.
    param([string]$Uri)
    try { $u = [uri]$Uri; return ('{0}://{1}{2}' -f $u.Scheme, $u.Authority, $u.AbsolutePath) } catch { return '(invalid url)' }
}

function ConvertFrom-KeystoneApiResponse {
    # Parse a JSON API response or throw a coded, body-free error.
    param([Parameter(Mandatory)][string]$Provider,[string]$Method,[string]$Endpoint,[Parameter(Mandatory)]$Response)
    $status = [int]$Response.Status
    if ($status -ge 200 -and $status -lt 300) {
        if ([string]::IsNullOrWhiteSpace($Response.Text)) { return $null }
        return ($Response.Text | ConvertFrom-Json)
    }
    $code = Get-KeystoneProviderErrorCode -Status $status -Headers $Response.Headers
    $detail = [string]$Response.Text
    if ($detail.Length -gt 500) { $detail = $detail.Substring(0,500) + '...' }
    if ($status -eq 0) { $detail = $Response.NetworkError }
    Write-KeystoneLog -Level ERROR -Message ("{0} API fail {1} {2} status={3} {4}" -f $Provider, $Method, $Endpoint, $status, $detail)
    $statusText = if ($status) { [string]$status } else { 'no response' }
    throw ("{0}|{1} API {2} {3} failed (HTTP {4})." -f $code, $Provider, $Method, $Endpoint, $statusText)
}

function Invoke-KeystoneDownload {
    # Download to a new file, following up to 3 redirects. The auth headers go
    # only to the original host; a redirect to another host (GitHub codeload,
    # object storage) is fetched without them, as those URLs are pre-signed.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$Uri,[hashtable]$AuthHeaders = @{},[Parameter(Mandatory)][string]$OutFile,[int]$TimeoutSec = 300)
    $origin = ([uri]$Uri).Authority
    $current = $Uri
    for ($hop = 0; $hop -le 3; $hop++) {
        $sameHost = (([uri]$current).Authority -eq $origin)
        $headers = if ($sameHost) { $AuthHeaders } else { @{ 'User-Agent' = 'Keystone' } }
        if (([uri]$current).Scheme -ne ([uri]$Uri).Scheme -and ([uri]$current).Scheme -ne 'https') { throw "NETWORK|$Provider download redirected to an insecure address." }
        $r = Invoke-KeystoneHttpRequest -Method GET -Uri $current -Headers $headers -OutFile $OutFile -TimeoutSec $TimeoutSec
        if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Headers['location']) {
            $current = ([uri]::new([uri]$current, [string]$r.Headers['location'])).AbsoluteUri
            continue
        }
        if ($r.File) { return $r.File }
        [void](ConvertFrom-KeystoneApiResponse -Provider $Provider -Method GET -Endpoint (Get-KeystoneSafeUrl $current) -Response $r)
        throw "NETWORK|$Provider download returned no content."
    }
    throw "NETWORK|$Provider download redirected too many times."
}
