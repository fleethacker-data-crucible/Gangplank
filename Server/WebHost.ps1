#Requires -Version 5.1
# Gangplank browser host entry: app state + HTTP loop + job pump + console keys,
# and the lifecycle (Core/Lifecycle.ps1): the browser tab owns the host.

function Start-GangplankWebHost {
    [CmdletBinding()]
    param(
        [int]$Port = 8769,
        [switch]$NoBrowser,
        [switch]$LocalDev,
        [string]$DevGitHubUrl,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$LegacyStateRoot,
        [switch]$WorkRootFixed,
        [Parameter(Mandatory)][string]$UiRoot,
        # Stop by itself once its last tab is gone (Test-GangplankAutoStopEnabled).
        [bool]$AutoStop = $true,
        # Folder whose Logs\ gets the runtime file (gangplank-server-<pid>.json).
        [string]$RuntimeRoot
    )
    if ($DevGitHubUrl) {
        if (-not $LocalDev) { throw 'A synthetic provider (-DevGitHubUrl) is only allowed with -LocalDev.' }
        Set-GangplankDevProvider -GitHubUrl $DevGitHubUrl
    }
    Initialize-GangplankApp -WorkRoot $WorkRoot -StateRoot $StateRoot -LegacyStateRoot $LegacyStateRoot -WorkRootFixed:$WorkRootFixed -LocalDev:$LocalDev
    Reset-GangplankPresence -AutoStop $AutoStop
    $script:GangplankHostLife = @{ AutoStop = $AutoStop; RuntimeFile = $null; StopEvent = $null; StopReason = $null; Pending = $null; WaitLogged = $false }
    $onReady = {
        param($Url)
        # Runtime file and stop event first: anything that sees the link can already find this host.
        if ($RuntimeRoot) {
            try { $script:GangplankHostLife.RuntimeFile = Write-GangplankRuntimeFile -Root $RuntimeRoot -Port (Get-GangplankHttpPort) -Url ('http://127.0.0.1:{0}/' -f (Get-GangplankHttpPort)) -StateRoot $StateRoot }
            catch { Write-GangplankLog -Level WARN -Message "Runtime file not written: $($_.Exception.Message)" }
        }
        $script:GangplankHostLife.StopEvent = New-GangplankStopEvent
        Write-GangplankLog -Level INFO -Message ('Web host started: PID {0}, port {1}, auto-stop {2}' -f $PID, (Get-GangplankHttpPort), $script:GangplankHostLife.AutoStop)
        Write-Host ''
        Write-Host '  GANGPLANK  |  Workspace' -ForegroundColor Cyan
        if ($LocalDev) { Write-Host '  [LOCAL DEV] Test mode: use fictional data only.' -ForegroundColor Yellow }
        Write-Host "  Open: $Url" -ForegroundColor Green
        Write-Host '  The link works once, for 2 minutes. Press L here for a new one. Ctrl+C stops Gangplank.' -ForegroundColor DarkGray
        if ($script:GangplankHostLife.AutoStop) {
            Write-Host '  Stops when its browser tab closes (or End session). Keep it running: --stay or GANGPLANK_AUTO_STOP=0.' -ForegroundColor DarkGray
        } else {
            Write-Host '  Keeps running after the browser tab closes. Stop: End session, Ctrl+C or Stop-Gangplank.ps1.' -ForegroundColor DarkGray
        }
        if (-not $NoBrowser) {
            try { Start-Process $Url | Out-Null } catch { Write-Host 'Open the link above in Edge or Chrome.' -ForegroundColor Yellow }
        }
    }
    $onTick = {
        Update-GangplankJobs
        Update-GangplankHostLifecycle
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'L') {
                    [void](New-GangplankLaunchNonce)
                    Write-Host ("  New link: {0}" -f (Get-GangplankLaunchUrl)) -ForegroundColor Green
                }
            }
        } catch { }   # no interactive console (tests, hidden window)
    }
    try {
        Start-GangplankHttpServer -PreferredPort $Port -UiRoot $UiRoot -OnReady $onReady -OnTick $onTick
    } finally {
        $life = $script:GangplankHostLife
        if ($life.StopReason) {
            Write-Host ''
            Write-Host ('  ' + $life.StopReason) -ForegroundColor Yellow
            Write-GangplankLog -Level INFO -Message ('Web host stopping: ' + $life.StopReason)
        }
        if ($life.StopEvent) { try { $life.StopEvent.Dispose() } catch { } }
        Remove-GangplankRuntimeFile -Path $life.RuntimeFile
    }
}

function Request-GangplankHostStop {
    <#
      Ask the host to stop once it is idle: End session, Stop-Gangplank.ps1 (named
      event) and auto-stop all come here. Running background jobs (a save, a
      download) finish first; the HTTP loop then stops on the next tick.
    #>
    param([Parameter(Mandatory)][string]$Reason)
    if ($null -eq $script:GangplankHostLife) { Stop-GangplankHttpServer; return }
    if (-not $script:GangplankHostLife.Pending) { $script:GangplankHostLife.Pending = $Reason }
}

function Update-GangplankHostLifecycle {
    # Called on the main thread between requests (OnTick), never during one.
    $life = $script:GangplankHostLife
    if ($null -eq $life) { return }
    if (-not $life.Pending) {
        if ($life.StopEvent -and $life.StopEvent.WaitOne(0)) { $life.Pending = 'Stop requested by Stop-Gangplank.ps1 or a new launch.' }
        elseif (Test-GangplankBrowserGone) { $life.Pending = 'Browser tab closed; Gangplank stops itself (GANGPLANK_AUTO_STOP=0 or --stay keeps it running).' }
    }
    if (-not $life.Pending) { return }
    if (Test-GangplankJobsBusy) {
        if (-not $life.WaitLogged) {
            $life.WaitLogged = $true
            Write-Host '  Stopping after the running background task finishes...' -ForegroundColor DarkGray
            Write-GangplankLog -Level INFO -Message ('Stop pending until background jobs finish: ' + $life.Pending)
        }
        return
    }
    $life.StopReason = $life.Pending
    Stop-GangplankHttpServer
}

function Get-GangplankHostLifecycleState {
    if ($null -eq $script:GangplankHostLife) { return @{ autoStop = $false; stopping = $false } }
    return @{ autoStop = [bool]$script:GangplankHostLife.AutoStop; stopping = [bool]$script:GangplankHostLife.Pending }
}
