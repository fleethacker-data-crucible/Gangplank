#Requires -Version 5.1
# Host half of the Fairlead client (Core/Intelligence.ps1 is the shared half).
# Before any client key is sent:
#   1. Exactly one process may listen on the loopback port.
#   2. GET /__fleethacker/id (no key, no redirect, no proxy) must say tool fairlead,
#      with that process's pid and a path that is exactly its executable or -File script.
#   3. Nothing listening on port 8776: start Fairlead through edge-ops Start-FleetService.
# The check tells an honest program that happens to hold the port from Fairlead. It is not
# authentication: a program running as this Windows account can name its own pid and path,
# and can read the key from Credential Manager directly.

$script:GangplankFairleadReadyOverride = $null
$script:GangplankFairleadListeners = $null
$script:GangplankFairleadProcessPaths = $null
$script:GangplankFleetServiceStart = $null
# Tests set this to a missing file so a suite never imports a real FleetPort module.
$script:GangplankFleetPortModulePath = $null

function ConvertTo-GangplankNormalPath {
    # Absolute Windows path, separators normalized, . and .. removed, or '' when it is not one.
    # No filesystem access, so a relative path or a '..' climb cannot be compared as a substring.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"').Replace('/','\')
    $drive = ''
    $rest = ''
    if ($p -match '^([A-Za-z]:)\\(.*)$') {
        $drive = $Matches[1]
        $rest = $Matches[2]
    } elseif ($p -match '^(\\\\[^\\]+\\[^\\]+)\\(.*)$') {
        $drive = $Matches[1]
        $rest = $Matches[2]
    } else { return '' }
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($seg in ($rest -split '\\')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') {
            if ($stack.Count -eq 0) { return '' }
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        [void]$stack.Add($seg)
    }
    if ($stack.Count -eq 0) { return ($drive + '\') }
    return ($drive + '\' + ($stack -join '\'))
}

function Get-GangplankPathLeaf {
    param([string]$Path)
    if (-not $Path) { return '' }
    $n = $Path.Replace('/','\')
    $i = $n.LastIndexOf('\')
    if ($i -ge 0 -and $i -lt ($n.Length - 1)) { return $n.Substring($i + 1) }
    return $n
}

function Test-GangplankFairleadPathMatch {
    # True only when the reported path is exactly the process executable or its -File script.
    param([string]$Reported,[string]$ExecutablePath,[string]$ScriptPath)
    $want = ConvertTo-GangplankNormalPath $Reported
    if (-not $want) { return $false }
    foreach ($candidate in @($ExecutablePath, $ScriptPath)) {
        $c = ConvertTo-GangplankNormalPath $candidate
        if ($c -and [string]::Equals($c, $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-GangplankNetstatListenerPids {
    # PIDs from English `netstat -ano -p tcp` that accept a connection to this loopback port.
    # $null is not used: an empty result is an empty array. Unreadable output throws AI_PORT_CHECK.
    param([string]$Text,[int]$Port)
    if ($Text -notmatch 'LISTENING') {
        throw 'AI_PORT_CHECK|Gangplank could not read which program listens on the Fairlead port, so the key was not sent.'
    }
    $pids = New-Object System.Collections.Generic.List[int]
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -notmatch 'LISTENING') { continue }
        if ($line -notmatch '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') { continue }
        $addr = $Matches[1]
        $linePort = 0
        $proc = 0
        if (-not [int]::TryParse($Matches[2],[ref]$linePort) -or -not [int]::TryParse($Matches[3],[ref]$proc)) { continue }
        if ($linePort -ne $Port -or $proc -le 0) { continue }
        $acceptsLoopback = $addr -in @('127.0.0.1','[::1]','::1','0.0.0.0','[::]','::','*')
        if (-not $acceptsLoopback) { continue }
        if (-not $pids.Contains($proc)) { [void]$pids.Add($proc) }
    }
    # One pid per pipeline object. An empty result writes nothing, so the caller gets an empty array.
    foreach ($procId in $pids) { $procId }
}

function Get-GangplankFairleadListenerPids {
    param([int]$Port)
    if ($script:GangplankFairleadListeners) {
        return @(& $script:GangplankFairleadListeners $Port | Where-Object { $_ })
    }
    if ($env:OS -ne 'Windows_NT') {
        throw 'AI_PORT_CHECK|Gangplank cannot see which program holds the Fairlead port on this system, so the key was not sent.'
    }
    $out = @(& netstat.exe -ano -p tcp 2>$null)
    if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) {
        throw 'AI_PORT_CHECK|Gangplank could not read which program listens on the Fairlead port, so the key was not sent.'
    }
    return @(Get-GangplankNetstatListenerPids -Text ($out -join "`n") -Port $Port)
}

function Get-GangplankProcessPaths {
    # ExecutablePath and the -File script of a process, from this PC. Never from the program's own claim.
    param([int]$ProcessId)
    if ($script:GangplankFairleadProcessPaths) {
        $got = & $script:GangplankFairleadProcessPaths $ProcessId
        if ($got) { return $got }
    }
    $empty = @{ ExecutablePath = ''; ScriptPath = '' }
    if ($env:OS -ne 'Windows_NT' -or $ProcessId -le 0) { return $empty }
    try {
        $p = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop
        $exe = [string]$p.ExecutablePath
        $cmd = [string]$p.CommandLine
        $scriptPath = ''
        if ($cmd -match '(?i)(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))') {
            if ($Matches[1]) { $scriptPath = $Matches[1] } else { $scriptPath = $Matches[2] }
        }
        return @{ ExecutablePath = $exe; ScriptPath = $scriptPath }
    } catch { return $empty }
}

function Invoke-GangplankFairleadIdRequest {
    # GET /__fleethacker/id. No Authorization header, no proxy, no redirect. Body capped at 4 KB.
    param([Parameter(Mandatory)][string]$Url)
    $request = [pscustomobject]@{
        Method = 'GET'
        Uri = $Url
        Headers = @{ Accept = 'application/json'; 'User-Agent' = 'Gangplank' }
        Body = $null
        OutFile = $null
        TimeoutSec = 3
    }
    if ($script:GangplankHttpTransport) { return (& $script:GangplankHttpTransport $request) }
    $resp = $null
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Accept = 'application/json'
        $req.UserAgent = 'Gangplank'
        $req.Timeout = 3000
        $req.ReadWriteTimeout = 3000
        $req.AllowAutoRedirect = $false
        try { $req.Proxy = $null } catch { }
        try { $resp = $req.GetResponse() }
        catch [Net.WebException] {
            $resp = $_.Exception.Response
            if (-not $resp) {
                return [pscustomobject]@{ Status = 0; Headers = @{}; Text = ''; File = $null; NetworkError = $_.Exception.Status.ToString() }
            }
        }
        $status = [int]$resp.StatusCode
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(),[Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($text -and $text.Length -gt 4096) { $text = '' }
        return [pscustomobject]@{ Status = $status; Headers = @{}; Text = $text; File = $null; NetworkError = '' }
    } catch {
        return [pscustomobject]@{ Status = 0; Headers = @{}; Text = ''; File = $null; NetworkError = $_.Exception.GetType().Name }
    } finally {
        if ($resp) { try { $resp.Dispose() } catch { } }
    }
}

function Resolve-GangplankFairleadIdentity {
    # Pure decision: listeners, the id document, and the process paths. Ok, or a coded refusal.
    param($Id,[int[]]$ListenerPids,[string]$ExecutablePath,[string]$ScriptPath,[string]$Authority)
    $not = 'Something other than Fairlead is answering at ' + $Authority + ', so the key was not sent.'
    $pids = @($ListenerPids | Where-Object { $_ })
    if ($pids.Count -eq 0) {
        return @{ Ok = $false; Code = 'AI_DOWN'; Message = ('Fairlead is not running at ' + $Authority + '.') }
    }
    if ($pids.Count -gt 1) {
        return @{ Ok = $false; Code = 'AI_NOT_FAIRLEAD'; Message = $not }
    }
    $owner = [int]$pids[0]
    if ($null -eq $Id) {
        return @{ Ok = $false; Code = 'AI_NOT_FAIRLEAD'; Message = ('The program at ' + $Authority + ' did not identify itself as Fairlead, so the key was not sent.') }
    }
    $tool = ''
    $toolProp = $Id.PSObject.Properties['tool']
    if ($toolProp -and $toolProp.Value) { $tool = [string]$toolProp.Value }
    if ($tool -cne 'fairlead') {
        $who = 'something else'
        if ($tool -cmatch '\A[A-Za-z0-9._-]{1,40}\z') { $who = '"' + $tool + '"' }
        return @{ Ok = $false; Code = 'AI_NOT_FAIRLEAD'; Message = ('The program at ' + $Authority + ' is ' + $who + ', not Fairlead, so the key was not sent.') }
    }
    $idPid = 0
    $pidProp = $Id.PSObject.Properties['pid']
    $pidText = ''
    if ($pidProp) { $pidText = [string]$pidProp.Value }
    if (-not [int]::TryParse($pidText,[ref]$idPid) -or $idPid -ne $owner) {
        return @{ Ok = $false; Code = 'AI_NOT_FAIRLEAD'; Message = $not }
    }
    $pathProp = $Id.PSObject.Properties['path']
    $reported = ''
    if ($pathProp -and $pathProp.Value) { $reported = [string]$pathProp.Value }
    if (-not $reported) {
        $scriptNorm = ConvertTo-GangplankNormalPath $ScriptPath
        $exeNorm = ConvertTo-GangplankNormalPath $ExecutablePath
        $leaf = Get-GangplankPathLeaf $exeNorm
        if ($scriptNorm -and $scriptNorm -match '(?i)\\scripts\\Start-Fairlead\.ps1\z') { $reported = $scriptNorm }
        elseif ($exeNorm -and $leaf -match '(?i)\Afairlead[\w.-]*\.exe\z') { $reported = $exeNorm }
        else {
            return @{ Ok = $false; Code = 'AI_NOT_FAIRLEAD'; Message = ('The program at ' + $Authority + ' says it is Fairlead but reports no path, and it does not run Fairlead''s start script, so the key was not sent.') }
        }
    }
    if (-not (Test-GangplankFairleadPathMatch -Reported $reported -ExecutablePath $ExecutablePath -ScriptPath $ScriptPath)) {
        return @{ Ok = $false; Code = 'AI_NOT_FAIRLEAD'; Message = $not }
    }
    return @{ Ok = $true; Code = ''; Message = '' }
}

function Test-GangplankFairleadIdentity {
    param([Parameter(Mandatory)][string]$Authority,[Parameter(Mandatory)][int]$Port)
    $listeners = @()
    try { $listeners = @(Get-GangplankFairleadListenerPids -Port $Port) }
    catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '^AI_PORT_CHECK\|(.*)$') {
            return @{ Ok = $false; Code = 'AI_PORT_CHECK'; Message = $Matches[1] }
        }
        return @{ Ok = $false; Code = 'AI_PORT_CHECK'; Message = 'Gangplank could not read which program listens on the Fairlead port, so the key was not sent.' }
    }
    $id = $null
    $exe = ''
    $scriptPath = ''
    if ($listeners.Count -eq 1) {
        $paths = Get-GangplankProcessPaths -ProcessId ([int]$listeners[0])
        if ($paths) {
            if ($paths.ExecutablePath) { $exe = [string]$paths.ExecutablePath }
            if ($paths.ScriptPath) { $scriptPath = [string]$paths.ScriptPath }
        }
        $response = $null
        try { $response = Invoke-GangplankFairleadIdRequest -Url ($Authority.TrimEnd('/') + '/__fleethacker/id') } catch { $response = $null }
        if ($response -and [int]$response.Status -eq 200 -and $response.Text -and ([string]$response.Text).Length -le 4096) {
            try { $id = [string]$response.Text | ConvertFrom-Json } catch { $id = $null }
        }
    }
    return (Resolve-GangplankFairleadIdentity -Id $id -ListenerPids $listeners -ExecutablePath $exe -ScriptPath $scriptPath -Authority $Authority)
}

function Find-GangplankFleetPortModule {
    # FleetPort.psm1 beside this checkout, or under the user's Projects\edge-ops. Nothing else is searched.
    if ($null -ne $script:GangplankFleetPortModulePath) {
        if ($script:GangplankFleetPortModulePath -and (Test-Path -LiteralPath $script:GangplankFleetPortModulePath -PathType Leaf)) {
            return [string]$script:GangplankFleetPortModulePath
        }
        return $null
    }
    $root = $script:GangplankRoot
    if (-not $root) { $root = Split-Path $PSScriptRoot -Parent }
    $candidates = New-Object System.Collections.Generic.List[string]
    $parent = Split-Path $root -Parent
    if ($parent) { [void]$candidates.Add((Join-Path $parent 'edge-ops\tools\fleet-port\FleetPort.psm1')) }
    foreach ($base in @($env:USERPROFILE, $env:HOME)) {
        if ($base) { [void]$candidates.Add((Join-Path $base 'Projects\edge-ops\tools\fleet-port\FleetPort.psm1')) }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

function Start-GangplankFairleadService {
    # Start-FleetService -Name fairlead. The key is not passed. A missing module is 'unavailable', not a throw.
    if ($script:GangplankFleetServiceStart) { return (& $script:GangplankFleetServiceStart) }
    $module = Find-GangplankFleetPortModule
    if (-not $module) {
        return @{ State = 'unavailable'; Message = 'Fairlead is not running, and Start-FleetService was not found (edge-ops\tools\fleet-port\FleetPort.psm1 next to Gangplank, or in Projects\edge-ops).' }
    }
    try {
        Import-Module -Name $module -Force -WarningAction SilentlyContinue -ErrorAction Stop
        $r = Start-FleetService -Name fairlead -WaitSeconds 40 -ErrorAction Stop
        $state = [string]$r.State
        $message = ''
        if ($r.Message) { $message = [string]$r.Message }
        if ($state -notin @('running','starting','unavailable')) { $state = 'unavailable' }
        return @{ State = $state; Message = $message }
    } catch {
        return @{ State = 'unavailable'; Message = ('Fairlead could not be started (' + $_.Exception.GetType().Name + ').') }
    }
}

function Assert-GangplankFairleadReady {
    # Throws a coded error when the key must not be sent. Tests may replace the whole check.
    if ($script:GangplankFairleadReadyOverride) {
        & $script:GangplankFairleadReadyOverride
        return
    }
    $cfg = Get-GangplankAiConfiguration
    $uri = [uri]$cfg.Url
    $authority = $uri.GetLeftPart([UriPartial]::Authority)
    $result = Test-GangplankFairleadIdentity -Authority $authority -Port $uri.Port
    if ($result.Ok) { return }
    $canStart = ($result.Code -eq 'AI_DOWN' -and $uri.IsLoopback -and $uri.Port -eq 8776)
    if ($canStart) {
        $started = Start-GangplankFairleadService
        if ($started.State -eq 'running' -or $started.State -eq 'starting') {
            $result = Test-GangplankFairleadIdentity -Authority $authority -Port $uri.Port
            if ($result.Ok) { return }
        } elseif ($started.Message) {
            throw ('AI_DOWN|' + [string]$started.Message)
        }
    }
    $code = 'AI_NOT_FAIRLEAD'
    if ($result.Code) { $code = [string]$result.Code }
    $message = 'Fairlead did not identify itself, so the key was not sent.'
    if ($result.Message) { $message = [string]$result.Message }
    Write-GangplankLog -Level WARN -Message ("Fairlead check refused the key: " + $code)
    throw ($code + '|' + $message)
}
