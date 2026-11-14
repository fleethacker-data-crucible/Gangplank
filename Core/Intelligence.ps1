#Requires -Version 5.1
# ============================================================
#  Core/Intelligence.ps1 - every AI call goes to Fairlead
#  Gangplank calls one address, the Fleet router (Fairlead) on this PC, with a route name.
#  It holds no gateway address, no provider token and no model id of its own.
#    Address   GANGPLANK_FAIRLEAD_URL (loopback only), default http://127.0.0.1:8776/v1/chat/completions
#    Route     GANGPLANK_FAIRLEAD_MODEL, default 'auto'
#    Key       Windows Credential Manager, generic credential Fairlead/Gangplank (Fairlead writes it:
#              Fairlead, Clients, install a key for Gangplank). If that credential is absent, the first
#              line of %LOCALAPPDATA%\Fairlead\local-token (Fairlead's own file for this Windows account).
#              Never an environment variable or a vault item. FAIRLEAD_LOCAL_TOKEN=off skips the file;
#              FAIRLEAD_LOCAL_TOKEN_FILE is Fairlead's own path for it.
#  The host's Assert-GangplankFairleadReady runs before the key is attached: /__fleethacker/id must be
#  Fairlead, and nothing on port 8776 is started with Start-FleetService. The id request carries no key.
#  Every request carries Authorization: Bearer <key>, X-Fairlead-Label: Gangplank and
#  X-Fairlead-Privacy: local, so prompts stay on this PC.
# ============================================================
# Shared module. Gangplank Intelligence, version 2.1.0 (docs/SHARED-AI-MODULE.md).
# Copied, not forked, into sibling products: change it here, bump the version, copy it back.
# Host functions it needs, and nothing else of Gangplank: Assert-GangplankFairleadReady,
# ConvertFrom-GangplankApiResponse, Get-GangplankSafeUrl, Invoke-GangplankHttpRequest.

$script:GangplankFairleadDefaultUrl = 'http://127.0.0.1:8776/v1/chat/completions'
$script:GangplankFairleadDefaultModel = 'auto'
$script:GangplankFairleadApp = 'Gangplank'
$script:GangplankFairleadTargetPattern = '^Fairlead/[A-Za-z][A-Za-z0-9-]{0,39}$'
# Replaceable for tests: { param([string]$Target) -> key text or $null }.
$script:GangplankFairleadKeyReader = $null
# Tests point this at a scratch file so a suite never reads the real local token.
$script:GangplankFairleadLocalTokenPath = $null

function Initialize-GangplankCredentialReader {
    if ('Gangplank.FairleadCredential' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Gangplank
{
    public static class FairleadCredential
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr buffer);

        // The raw blob of a generic credential, or null when there is none.
        public static byte[] ReadBlob(string target)
        {
            IntPtr p;
            if (!CredRead(target, 1, 0, out p)) return null;
            try
            {
                CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
                if (c.CredentialBlobSize <= 0 || c.CredentialBlob == IntPtr.Zero) return null;
                byte[] blob = new byte[c.CredentialBlobSize];
                Marshal.Copy(c.CredentialBlob, blob, 0, blob.Length);
                return blob;
            }
            finally { CredFree(p); }
        }
    }
}
'@
}

function ConvertFrom-GangplankCredentialBlob {
    # Credential Manager keeps the key as UTF-16 text (what Fairlead and cmdkey write); UTF-8 is accepted too.
    param([byte[]]$Blob)
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return $null }
    foreach ($enc in @([Text.Encoding]::Unicode, [Text.Encoding]::UTF8)) {
        $text = ($enc.GetString($Blob)).Trim([char]0, ' ', "`r", "`n")
        if (-not [string]::IsNullOrEmpty($text) -and $text -cmatch '^[\x21-\x7e]+$') { return $text }
    }
    return $null
}

function Get-GangplankFairleadTarget {
    # Fairlead/Gangplank. GANGPLANK_FAIRLEAD_TARGET may name another Fairlead/<App> credential (tests); it can never
    # point at anything outside the Fairlead/ names.
    $t = [Environment]::GetEnvironmentVariable('GANGPLANK_FAIRLEAD_TARGET')
    if ($t) {
        $t = $t.Trim()
        if ($t -cnotmatch $script:GangplankFairleadTargetPattern) { throw 'AI_TOKEN_MISSING|GANGPLANK_FAIRLEAD_TARGET must look like Fairlead/AppName.' }
        return $t
    }
    return ('Fairlead/' + $script:GangplankFairleadApp)
}

function Set-GangplankFairleadKeyReader {
    # Tests only. Pass $null to go back to Windows Credential Manager.
    param([scriptblock]$Reader)
    $script:GangplankFairleadKeyReader = $Reader
}

function Test-GangplankFairleadKeyShape {
    # A Fairlead client key: "fl-" then letters, digits, '-' or '_'. The local-token file is checked
    # before it is used. A Credential Manager blob keeps its own printable-text check.
    param([string]$Key)
    return ($null -ne $Key -and $Key -cmatch '\Afl-[A-Za-z0-9_-]{8,256}\z')
}

function Get-GangplankFairleadLocalTokenPath {
    if ($script:GangplankFairleadLocalTokenPath) { return $script:GangplankFairleadLocalTokenPath }
    $moved = [Environment]::GetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN_FILE')
    if (-not [string]::IsNullOrWhiteSpace($moved)) { return $moved.Trim().Trim('"') }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        try { $base = [Environment]::GetFolderPath('LocalApplicationData') } catch { $base = '' }
    }
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    return (Join-Path (Join-Path $base 'Fairlead') 'local-token')
}

function Read-GangplankFairleadLocalToken {
    # First line of Fairlead's local-token file, or $null. Never logged. A file over 4 KB is ignored.
    $off = [Environment]::GetEnvironmentVariable('FAIRLEAD_LOCAL_TOKEN')
    if ($off -and $off.Trim().ToLowerInvariant() -eq 'off') { return $null }
    $path = Get-GangplankFairleadLocalTokenPath
    try {
        if (-not $path -or -not [IO.File]::Exists($path)) { return $null }
        if ((New-Object IO.FileInfo $path).Length -gt 4096) { return $null }
        $text = [IO.File]::ReadAllText($path)
        $line = ($text -split '\r?\n', 2)[0]
        if ($null -eq $line) { return $null }
        $line = $line.Trim().TrimStart([char]0xFEFF)
        if (-not (Test-GangplankFairleadKeyShape $line)) { return $null }
        return $line
    } catch { return $null }
}

function Get-GangplankFairleadKey {
    # Credential Manager first (Fairlead/Gangplank), then Fairlead's local-token file. Never an env var.
    $target = Get-GangplankFairleadTarget
    $fromStore = $null
    if ($script:GangplankFairleadKeyReader) {
        $v = & $script:GangplankFairleadKeyReader $target
        if ($v) { $fromStore = ([string]$v).Trim() }
    } elseif ($env:OS -eq 'Windows_NT') {
        try {
            Initialize-GangplankCredentialReader
            $fromStore = ConvertFrom-GangplankCredentialBlob -Blob ([Gangplank.FairleadCredential]::ReadBlob($target))
        } catch { $fromStore = $null }
    }
    if ($fromStore) { return $fromStore }
    return (Read-GangplankFairleadLocalToken)
}

function Get-GangplankAiToken {
    # The Fairlead client key for this app, or $null.
    return (Get-GangplankFairleadKey)
}

function Get-GangplankAiRequestToken {
    # The key for a chat request. Without one Fairlead would refuse the call, so say what to do.
    param($Config)
    $key = Get-GangplankFairleadKey
    if (-not $key) { throw 'AI_TOKEN_MISSING|No Fairlead key for Gangplank. In Fairlead, open Clients and install a key, or start Fairlead once so it can write a local token for this Windows account.' }
    return $key
}

function Test-GangplankAiLoopbackUrl {
    # True when the URL points at this PC (127.0.0.0/8, ::1 or localhost).
    param([AllowEmptyString()][AllowNull()][string]$Url)
    $u = $null
    if ([string]::IsNullOrWhiteSpace($Url) -or -not [uri]::TryCreate($Url.Trim(),[UriKind]::Absolute,[ref]$u)) { return $false }
    return [bool]$u.IsLoopback
}

function Resolve-GangplankFairleadUrl {
    # Accepts http://127.0.0.1:8776, .../v1 or .../v1/chat/completions and returns the chat address.
    # Anything that is not this PC is refused: Gangplank talks to the router on this machine only.
    param([Parameter(Mandatory)][string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url.Trim(),[UriKind]::Absolute,[ref]$u) -or $u.UserInfo -or $u.Query -or $u.Fragment) {
        throw 'BAD_REQUEST|GANGPLANK_FAIRLEAD_URL must be a plain address such as http://127.0.0.1:8776.'
    }
    if ($u.Scheme -notin @('http','https')) { throw 'BAD_REQUEST|GANGPLANK_FAIRLEAD_URL must start with http:// or https://.' }
    if (-not $u.IsLoopback) { throw 'FORBIDDEN|Gangplank only talks to Fairlead on this PC. GANGPLANK_FAIRLEAD_URL must be a loopback address.' }
    $path = $u.AbsolutePath.TrimEnd('/')
    if ($path -match '(?i)/chat/completions$') { $chat = $path }
    elseif ($path -match '(?i)/v1$') { $chat = $path + '/chat/completions' }
    elseif (-not $path) { $chat = '/v1/chat/completions' }
    else { $chat = $path + '/v1/chat/completions' }
    return ($u.GetLeftPart([UriPartial]::Authority) + $chat)
}

function Get-GangplankAiConfiguration {
    $raw = [Environment]::GetEnvironmentVariable('GANGPLANK_FAIRLEAD_URL')
    $chat = Resolve-GangplankFairleadUrl -Url $(if ($raw) { $raw } else { $script:GangplankFairleadDefaultUrl })
    $model = [Environment]::GetEnvironmentVariable('GANGPLANK_FAIRLEAD_MODEL')
    if ($model) { $model = $model.Trim() } else { $model = $script:GangplankFairleadDefaultModel }
    if (-not $model -or $model.Length -gt 200 -or $model -match '[\x00-\x1f]') { throw 'AI_MODEL_MISSING|GANGPLANK_FAIRLEAD_MODEL must be a route name such as auto.' }
    return [pscustomobject]@{
        Endpoint = ([uri]$chat).GetLeftPart([UriPartial]::Authority)
        Model = $model
        Url = $chat
    }
}

function Get-GangplankAiAuthHeaders {
    param([string]$Token)
    # The key is attached only after the host has checked /__fleethacker/id (and started Fairlead if needed).
    if ($Token) { Assert-GangplankFairleadReady }
    $h = @{
        'Content-Type' = 'application/json'
        Accept = 'application/json'
        'X-Fairlead-Label' = $script:GangplankFairleadApp
        'X-Fairlead-Privacy' = 'local'
    }
    if ($Token) { $h['Authorization'] = "Bearer $Token" }
    return $h
}

function Get-GangplankAiSettingsView {
    $cfg = $null; $problem = ''
    try { $cfg = Get-GangplankAiConfiguration } catch { $problem = ([string]$_.Exception.Message -split '\|',2)[-1] }
    $key = $false
    try { $key = [bool](Get-GangplankFairleadKey) } catch { $key = $false }
    return [ordered]@{
        endpoint = $(if ($cfg) { $cfg.Endpoint } else { '' })
        model = $(if ($cfg) { $cfg.Model } else { '' })
        keyReady = $key
        credentialName = (Get-GangplankFairleadTarget)
        problem = $problem
    }
}

function Get-GangplankAiAnswerText {
    # The assistant text from an OpenAI-style answer.
    param($Response)
    if ($null -eq $Response) { return '' }
    $choices = $Response.PSObject.Properties['choices']
    if ($choices -and @($choices.Value).Count -gt 0) {
        $first = @($choices.Value)[0]
        $msg = $first.PSObject.Properties['message']
        if ($msg -and $msg.Value) {
            $content = $msg.Value.PSObject.Properties['content']
            if ($content -and $content.Value -is [string]) { return [string]$content.Value }
            if ($content -and $content.Value) { return (@($content.Value | ForEach-Object { if ($_.text) { [string]$_.text } elseif ($_ -is [string]) { $_ } }) -join '') }
        }
        if ($first.PSObject.Properties['text']) { return [string]$first.text }
    }
    return ''
}

function Test-GangplankAiConnection {
    # A tiny real request through Fairlead, so "ready" means "works".
    [CmdletBinding()]
    param([string]$Token)
    $config = Get-GangplankAiConfiguration
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $payload = @{ model = $config.Model; messages = @(@{ role = 'user'; content = 'Reply with the single word OK.' }); max_tokens = 5; temperature = 0 }
    $r = Invoke-GangplankHttpRequest -Method POST -Uri $config.Url -Headers (Get-GangplankAiAuthHeaders -Token $Token) -Body ($payload | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 30
    $doc = ConvertFrom-GangplankApiResponse -Provider 'AI' -Method POST -Endpoint (Get-GangplankSafeUrl $config.Url) -Response $r
    $text = Get-GangplankAiAnswerText -Response $doc
    return [ordered]@{ ok = $true; model = $config.Model; milliseconds = [int]$clock.ElapsedMilliseconds; reply = $(if ($text.Length -gt 40) { $text.Substring(0,40) } else { $text }) }
}
