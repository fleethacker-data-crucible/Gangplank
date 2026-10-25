#Requires -Version 5.1
<#
.SYNOPSIS
  Keystone local browser workspace. Windows PowerShell 5.1, no git.exe or Node required.
.DESCRIPTION
  Binds only to localhost, requires per-process CSRF token on writes, and never
  exposes Git/AI tokens through the browser.

  The browser tab owns the host: the page sends a heartbeat every 5 seconds and
  the host stops itself 20 seconds after the last one (5 seconds after the tab
  says it is leaving). A reload does not stop it; with several tabs open it stops
  when the last one is gone. End session in the browser, Ctrl+C here, or
  Stop-Keystone.ps1 also stop it. The host finishes the request it is serving
  (a save, a download) before it stops.
.PARAMETER Stay
  Keep running after the browser tab closes. Also --stay, or KEYSTONE_AUTO_STOP=0
  (environment), or "AutoStop": false in config\keystone-config.json.
.PARAMETER Replace
  If Keystone is already running from this folder, stop it and start fresh without
  asking. Also --replace.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateRange(1025,65535)][int]$Port = 8769,
    [switch]$NoBrowser,
    [switch]$SkipArcUnlock,
    [switch]$LocalDev,
    [switch]$Stay,
    [switch]$Replace,
    # Launcher-style options (--stay, --replace, --no-browser) and a bare port number.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
foreach ($a in @($Rest)) {
    if (-not $a) { continue }
    switch -Regex ($a) {
        '^--?stay$' { $Stay = $true; continue }
        '^--?replace$' { $Replace = $true; continue }
        '^--?no-?browser$' { $NoBrowser = $true; continue }
        '^--?local-?dev$' { $LocalDev = $true; continue }
        '^\d{4,5}$' {
            $n = [int]$a
            if ($n -lt 1025 -or $n -gt 65535) { throw "Port $a is out of range (1025-65535)." }
            $Port = $n; continue
        }
        default { Write-Warning "Ignoring unknown option $a" }
    }
}
# CI and other unattended runs set KEYSTONE_LOCAL_DEV=1: never import ARC or prompt for CAC/TOTP.
if ($env:KEYSTONE_LOCAL_DEV -eq '1') { $LocalDev = $true }
. (Join-Path $root 'Core\Lifecycle.ps1')
# One instance: a host from this folder that is still running (often a hidden window
# whose tab was closed) holds the port. Stop it before ARC asks for CAC/TOTP.
$running = @(Get-KeystoneServerProcesses -Root $root -ThisCheckout)
if ($running.Count -gt 0) {
    $where = ($running | ForEach-Object { Format-KeystoneServerProcess -Process $_ }) -join ', '
    Write-Host ('Keystone is already running: ' + $where) -ForegroundColor Yellow
    $answer = 'y'
    $interactive = $true
    try { if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { $interactive = $false } } catch { $interactive = $false }
    if (-not $Replace -and $interactive) {
        try { $answer = Read-Host 'Stop it and start fresh? [Y/n]' } catch { $answer = 'n' }
    } elseif (-not $Replace) {
        Write-Host '  No console to ask in; stopping it (the default answer).' -ForegroundColor DarkGray
    }
    if ($answer -eq '' -or $answer -match '^[Yy]') {
        foreach ($p in @(Stop-KeystoneServerProcesses -Root $root -ThisCheckout)) {
            Write-Host ('  Stopped Keystone ' + (Format-KeystoneServerProcess -Process $p)) -ForegroundColor DarkGray
        }
    } else {
        Write-Host 'Leaving the running Keystone alone. Use End session in its browser tab, or Stop-Keystone.ps1.' -ForegroundColor DarkGray
        exit 0
    }
}
Import-Module (Join-Path $root 'Keystone.psm1') -Force
Initialize-Keystone
$autoStop = Test-KeystoneAutoStopEnabled -Stay:$Stay -Config (Get-KeystoneConfig)
Reset-KeystonePresence -AutoStop $autoStop
# Import ARC ONCE and perform its normal CAC/TOTP unlock before serving any
# browser requests. The browser never starts an ARC authentication prompt.
# LocalDev deliberately does not import pm.ps1 or open the real ARC vault.
$arcState = if ($LocalDev) { [pscustomobject]@{ Unlocked = $false } } else { Initialize-KeystoneArcAuthentication -SkipUnlock:$SkipArcUnlock }
if ($LocalDev) { Write-Host '[LOCAL DEV] ARC is not imported; CAC/TOTP and vault operations remain disabled.' -ForegroundColor Yellow }
if (-not $arcState.Unlocked) {
    Write-Host '[!] ARC is not unlocked. Keystone can still use approved environment tokens.' -ForegroundColor Yellow
    Write-Host '[!] To use ARC, restart Keystone and complete the CAC/TOTP steps in THIS console.' -ForegroundColor DarkGray
}
$session = $null
$buffer = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
$csrf = [Convert]::ToBase64String($buffer)
$nonce = [Convert]::ToBase64String($buffer).Replace('+','').Replace('/','').Replace('=','')
$listener = New-Object Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)

function Send-KeystoneWebJson {
    param($Response,[int]$Status = 200,$Value)
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes,0,$bytes.Length)
}
function Read-KeystoneWebBody {
    param($Request)
    if ($Request.ContentLength64 -lt 0 -or $Request.ContentLength64 -gt 131072) {
        throw 'Request must provide a Content-Length no greater than 128 KB.'
    }
    if ($Request.ContentType -notmatch '^application/json(?:\s*;|$)') { throw 'Expected application/json.' }
    $reader = New-Object IO.StreamReader($Request.InputStream,[Text.Encoding]::UTF8)
    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 131072) { throw 'Request is too large.' }
    if (-not $body) { throw 'Request body is empty.' }
    return ($body | ConvertFrom-Json)
}
function Test-KeystoneWebRequest {
    param($Request,[int]$Port,[string]$Csrf)
    if (-not [Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address)) { return $false }
    if ($Request.Url.Host -ne 'localhost' -or $Request.Url.Port -ne $Port) { return $false }
    $origin = $Request.Headers['Origin']
    if ($origin -and $origin -ne "http://localhost:$Port") { return $false }
    if ($Request.HttpMethod -eq 'POST') {
        $header = $Request.Headers['X-Keystone-Session']
        # The tab's unload beacon (navigator.sendBeacon) cannot set headers. That one
        # route checks the token in its JSON body instead; nothing else may skip it.
        if (-not $header -and $Request.Url.AbsolutePath -eq '/api/heartbeat') { return $true }
        if ($header -cne $Csrf) { return $false }
    }
    return $true
}

try {
    $listener.Start()
} catch {
    throw "Unable to start localhost listener on $prefix. If another Keystone (for example from a different folder) is running, stop it with Stop-Keystone.ps1. Otherwise choose an unused port, or ask IT whether HttpListener requires a URL reservation. $($_.Exception.Message)"
}
Write-Host ''
Write-Host '  KEYSTONE  |  Enterprise Workspace' -ForegroundColor Cyan
Write-Host "  Browser: $prefix" -ForegroundColor Green
Write-Host '  Localhost only. Ctrl+C to stop. Repository secrets remain server-side.' -ForegroundColor DarkGray
if ($autoStop) {
    Write-Host '  Stops when its browser tab closes (or End session). Keep it running: --stay or KEYSTONE_AUTO_STOP=0.' -ForegroundColor DarkGray
} else {
    Write-Host '  Keeps running after the browser tab closes. Stop: End session, Ctrl+C or Stop-Keystone.ps1.' -ForegroundColor DarkGray
}
Write-Host '  ARC: see Integrations in the browser for per-provider credential status.' -ForegroundColor DarkGray
$runtimeFile = $null
$stopEvent = $null
$stopReason = $null
$pending = $null
try {
    $runtimeFile = Write-KeystoneRuntimeFile -Root $root -Port $Port -Url $prefix
    $stopEvent = New-KeystoneStopEvent
    Write-KeystoneLog -Level INFO -Message ("Web host started: PID {0}, {1}, auto-stop {2}" -f $PID, $prefix, $autoStop)
    if (-not $NoBrowser) {
        try { Start-Process $prefix | Out-Null }
        catch { Write-Host "Open this URL manually: $prefix" -ForegroundColor Yellow }
    }
    while ($listener.IsListening) {
        # Wait for a request in short slices, so the host can notice between requests
        # that its tab is gone or that Stop-Keystone.ps1 asked it to stop. Requests are
        # served one at a time, so this never interrupts a save or a download.
        if ($stopEvent -and $stopEvent.WaitOne(0)) { $stopReason = 'Stop requested by Stop-Keystone.ps1 or a new launch.'; break }
        if (Test-KeystoneBrowserGone) { $stopReason = 'Browser tab closed; Keystone stops itself (KEYSTONE_AUTO_STOP=0 or --stay keeps it running).'; break }
        if ($null -eq $pending) { $pending = $listener.BeginGetContext($null, $null) }
        if (-not $pending.AsyncWaitHandle.WaitOne(1000)) { continue }
        $context = $listener.EndGetContext($pending)
        $pending = $null
        $req = $context.Request
        $res = $context.Response
        $path = $null
        $requestStarted = [DateTime]::UtcNow
        try {
            $res.Headers.Add('X-Content-Type-Options','nosniff')
            $res.Headers.Add('X-Frame-Options','DENY')
            $res.Headers.Add('Referrer-Policy','no-referrer')
            $res.Headers.Add('Cache-Control','no-store')
            $res.Headers.Add('Content-Security-Policy',"default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; connect-src 'self'; worker-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'")
            if (-not (Test-KeystoneWebRequest -Request $req -Port $Port -Csrf $csrf)) {
                Send-KeystoneWebJson -Response $res -Status 403 -Value @{ error = 'Request rejected by local session security policy.' }
                continue
            }
            $path = $req.Url.AbsolutePath
            if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
                $html = [IO.File]::ReadAllText((Join-Path $root 'web\index.html'),[Text.Encoding]::UTF8)
                $html = $html.Replace('__KEYSTONE_CSRF__',$csrf).Replace('__KEYSTONE_NONCE__',$nonce)
                $bytes = [Text.Encoding]::UTF8.GetBytes($html)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes,0,$bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/heartbeat-worker.js') {
                # Presence heartbeat worker: hidden tabs throttle main-thread timers, workers much less.
                $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'web\heartbeat-worker.js'))
                $res.ContentType = 'text/javascript; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes,0,$bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/heartbeat') {
                # Presence. Never log this body: the unload beacon carries the session token.
                $body = Read-KeystoneWebBody -Request $req
                if (-not $req.Headers['X-Keystone-Session']) {
                    $bodyToken = $null
                    if ($body.PSObject.Properties['session']) { $bodyToken = [string]$body.session }
                    if (-not $bodyToken -or $bodyToken -cne $csrf) {
                        Send-KeystoneWebJson -Response $res -Status 403 -Value @{ error = 'Request rejected by local session security policy.' }
                        continue
                    }
                }
                $tabId = $null
                if ($body.PSObject.Properties['tab']) { $tabId = [string]$body.tab }
                Register-KeystonePresence -TabId $tabId -Leaving:($body.leaving -eq $true)
                Send-KeystoneWebJson -Response $res -Value (Get-KeystonePresenceState)
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/session/stop') {
                if ($req.Headers['X-Keystone-Intent'] -cne 'end-session') { throw 'Ending the session requires the X-Keystone-Intent header.' }
                Write-KeystoneLog -Level INFO -Message 'End session requested from the browser.'
                Send-KeystoneWebJson -Response $res -Value @{ stopping = $true }
                $stopReason = 'End session requested from the browser.'
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
                Send-KeystoneWebJson -Response $res -Value @{
                    autoStop = $autoStop
                    connected = ($null -ne $session)
                    provider = $(if ($session) { $session.Provider } else { $null })
                    project = $(if ($session) { $session.ProjectPath } else { $null })
                    branch = $(if ($session) { $session.LastBranch } else { $null })
                    workspace = $(if ($session) { $session.LocalPath } else { $null })
                    ai = [bool]($env:KEYSTONE_AI_TOKEN -or $env:GENAI_TOKEN)
                    canReview = [bool]($session -and $session.LastSaveMessage -and -not $session.LastReviewUrl)
                }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/branches') {
                if (-not $session) { throw 'Connect a project first.' }
                Send-KeystoneWebJson -Response $res -Value @{ branches = @(Get-KeystoneRepositoryBranches -Session $session); defaultBranch=$session.DefaultBranch }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/history') {
                if (-not $session) { throw 'Connect a project first.' }
                $selected = [string]$req.QueryString['branch']
                Send-KeystoneWebJson -Response $res -Value @{ commits = @(Get-KeystoneRepositoryHistory -Session $session -Branch $selected); branch=$selected }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/compare') {
                if (-not $session) { throw 'Connect a project first.' }
                $base = [string]$req.QueryString['base']
                $head = [string]$req.QueryString['head']
                if (-not $base -or -not $head) { throw 'Choose two branches to compare.' }
                Send-KeystoneWebJson -Response $res -Value (Get-KeystoneRepositoryComparison -Session $session -Base $base -Head $head)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/reviews') {
                if (-not $session) { throw 'Connect a project first.' }
                Send-KeystoneWebJson -Response $res -Value @{ reviews = @(Get-KeystoneRepositoryReviews -Session $session) }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/insights') {
                if (-not $session) { throw 'Connect a project first.' }
                Send-KeystoneWebJson -Response $res -Value (Get-KeystoneRepositoryInsights -Session $session)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/sentinel') {
                if (-not $session) { throw 'Connect a project first.' }
                $destination = Get-KeystoneSentinelDestination -Session $session
                $findings = @()
                if ($session.LocalPath -and $session.BaselineSha) {
                    $preview = Get-KeystoneWorkspacePreview -Session $session
                    $paths = @($preview.Changes | Where-Object { $_.Kind -ne 'Deleted' } | ForEach-Object Path)
                    $report = Test-KeystoneSentinelPublication -Session $session -Paths $paths
                    $findings = @($report.Findings)
                }
                Send-KeystoneWebJson -Response $res -Value @{ destination = $destination; findings = $findings; publicPublishingEnabled = ($env:KEYSTONE_ALLOW_PUBLIC_PUBLISH -eq '1') }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/integrations') {
                $integration = Get-KeystoneArcConnectionStatus
                Send-KeystoneWebJson -Response $res -Value $integration
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/integrations/map') {
                $body = Read-KeystoneWebBody -Request $req
                $provider = [string]$body.provider
                $item = [string]$body.item
                if ($provider -notin @('GitHub','GitLab','GenAi')) { throw 'Unsupported credential provider.' }
                $names = @(Get-KeystoneArcServiceNames)
                if ($names.Count -gt 0 -and $item -notin $names) {
                    throw 'Select a service name that exists in the unlocked ARC catalog.'
                }
                [void](Set-KeystoneArcItemName -Provider $provider -ServiceName $item)
                Send-KeystoneWebJson -Response $res -Value (Get-KeystoneArcConnectionStatus)
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/connect') {
                $body = Read-KeystoneWebBody -Request $req
                if (-not $body.url -or ([string]$body.url).Length -gt 500) { throw 'Enter a valid GitHub or GitLab project URL.' }
                $session = Open-KeystoneRepository -Url ([string]$body.url)
                Send-KeystoneWebJson -Response $res -Value @{
                    project = $session.ProjectPath; provider = $session.Provider
                    branch = $session.DefaultBranch; branches = @($session.Branches)
                }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/start') {
                if (-not $session) { throw 'Connect a project first.' }
                $newBranch = New-KeystoneWorkBranch -Session $session
                $folder = Get-KeystoneSafeWorkspacePath -Base (Join-Path $root 'work') -Project $session.ProjectPath -Branch $newBranch
                $downloaded = Invoke-KeystonePull -Session $session -Branch $newBranch -LocalPath $folder
                Send-KeystoneWebJson -Response $res -Value @{ folder = $downloaded; branch = $newBranch; sha = $session.BaselineSha }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/download') {
                if (-not $session) { throw 'Connect a project first.' }
                $body = Read-KeystoneWebBody -Request $req
                $branch = if ($body.branch) { [string]$body.branch } else { $session.DefaultBranch }
                if ($branch.Length -gt 200) { throw 'Branch name is too long.' }
                $folder = Get-KeystoneSafeWorkspacePath -Base (Join-Path $root 'work') -Project $session.ProjectPath -Branch $branch
                $path = Invoke-KeystonePull -Session $session -Branch $branch -LocalPath $folder
                Send-KeystoneWebJson -Response $res -Value @{ folder = $path; branch = $branch; sha = $session.BaselineSha }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/preview') {
                if (-not $session -or -not $session.BaselineSha) {
                    Send-KeystoneWebJson -Response $res -Value @{ ready = $false; changes = @(); remoteChanged = $false }
                } else {
                    $preview = Get-KeystoneWorkspacePreview -Session $session
                    Send-KeystoneWebJson -Response $res -Value @{
                        ready = $true; changes = @($preview.Changes); remoteChanged = $preview.RemoteChanged
                        branch = $preview.Branch; message = $preview.SmartMessage.Title
                        workspace = $preview.LocalPath
                    }
                }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/commit-message') {
                if (-not $session) { throw 'Connect a project first.' }
                $body = Read-KeystoneWebBody -Request $req
                $preview = Get-KeystoneWorkspacePreview -Session $session
                $selected = @([string[]]@($body.paths))
                $known = @($preview.Changes | Where-Object { -not $_.Blocked } | ForEach-Object Path)
                foreach ($p in $selected) { if ($p -cnotin $known) { throw 'Invalid selected file.' } }
                if ($selected.Count -eq 0) { throw 'Select changed files first.' }
                $diff = [pscustomobject]@{
                    New = @($preview.Changes | Where-Object { $_.Kind -eq 'New' -and $_.Path -cin $selected } | ForEach-Object Path)
                    Modified = @($preview.Changes | Where-Object { $_.Kind -eq 'Modified' -and $_.Path -cin $selected } | ForEach-Object Path)
                    Deleted = @($preview.Changes | Where-Object { $_.Kind -eq 'Deleted' -and $_.Path -cin $selected } | ForEach-Object Path)
                }
                $prompt = Get-KeystoneSmartSavePrompt -Diff $diff
                $answer = Invoke-KeystoneAI -Question $prompt -CommitTitle
                $draft = New-KeystoneSmartMessage -Added $diff.New -Modified $diff.Modified -Deleted $diff.Deleted -AiSuggestion $answer
                Send-KeystoneWebJson -Response $res -Value @{ title = $draft.Title; source = $draft.Source }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/save') {
                if (-not $session) { throw 'Connect a project first.' }
                $body = Read-KeystoneWebBody -Request $req
                $selected = [string[]]@($body.paths)
                $message = if ($body.message) { [string]$body.message } else { '' }
                $publicConfirmed = ($body.publicConfirmed -eq $true)
                $saved = Invoke-KeystoneWorkspaceSave -Session $session -SelectedPaths $selected -Message $message -PublicConfirmed:$publicConfirmed
                $session | Add-Member -MemberType NoteProperty -Name LastSaveMessage -Value $saved.Message -Force
                $session | Add-Member -MemberType NoteProperty -Name LastSavedFiles -Value $selected -Force
                Send-KeystoneWebJson -Response $res -Value $saved
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/review') {
                if (-not $session -or -not $session.LastBranch) { throw 'Start a work branch before requesting review.' }
                if ($session.LastBranch -eq $session.DefaultBranch) { throw 'Cannot review the default branch against itself.' }
                if (-not $session.LastSaveMessage) { throw 'Save your changes before requesting review.' }
                if ($session.LastReviewUrl) {
                    Send-KeystoneWebJson -Response $res -Value @{ url = $session.LastReviewUrl; title = 'Review already created' }
                    continue
                }
                # Safe generated descriptions; no manually written PR text needed.
                $title = 'Review: ' + [string]$session.LastSaveMessage
                $desc = 'Created with Keystone Smart Save.' + [char]10 + [char]10 + 'Files in most recent save:' + [char]10
                foreach ($p in @($session.LastSavedFiles)) { $desc += '- ' + $p + [char]10 }
                $review = New-KeystoneMergeRequest -Session $session -SourceBranch $session.LastBranch -TargetBranch $session.DefaultBranch -Title $title -Description $desc
                $reviewUrl = if ($review.html_url) { [string]$review.html_url } else { [string]$review.web_url }
                $session | Add-Member -MemberType NoteProperty -Name LastReviewUrl -Value $reviewUrl -Force
                Send-KeystoneWebJson -Response $res -Value @{ url = $reviewUrl; title = $title }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/chat/stream') {
                $body = Read-KeystoneWebBody -Request $req
                if ([string]::IsNullOrWhiteSpace([string]$body.message)) { throw 'Enter a message.' }
                $res.ContentType = 'text/event-stream; charset=utf-8'
                $res.SendChunked = $true
                Invoke-KeystoneAIStream -Question ([string]$body.message) -Session $session -Response $res
            }
            else {
                Send-KeystoneWebJson -Response $res -Status 404 -Value @{ error = 'Route not found.' }
            }
        } catch {
            $message = $_.Exception.Message
            Write-KeystoneLog -Level WARN -Message "Web request failed: $path : $message"
            try {
                if ($res.SendChunked) {
                    Send-KeystoneSseEvent -Response $res -Event 'error' -Data $message
                } else {
                    Send-KeystoneWebJson -Response $res -Status 400 -Value @{ error = $message }
                }
            } catch { }
        } finally {
            try { $res.Close() } catch { }
            # Heartbeats queue behind a long request (save, download, AI chat); let them
            # arrive before deciding the tab is gone.
            if (([DateTime]::UtcNow - $requestStarted).TotalSeconds -ge 2) { Register-KeystoneRequestFinished }
        }
        if ($stopReason) { break }
    }
} finally {
    if ($stopReason) {
        Write-Host ''
        Write-Host ('  ' + $stopReason) -ForegroundColor Yellow
        Write-KeystoneLog -Level INFO -Message ('Web host stopping: ' + $stopReason)
    }
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    if ($stopEvent) { try { $stopEvent.Dispose() } catch { } }
    Remove-KeystoneRuntimeFile -Path $runtimeFile
}
