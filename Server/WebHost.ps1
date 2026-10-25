#Requires -Version 5.1
# Keystone browser host entry: app state + HTTP loop + job pump + console keys,
# and the lifecycle (Core/Lifecycle.ps1): the browser tab owns the host.

function Start-KeystoneWebHost {
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
        # Stop by itself once its last tab is gone (Test-KeystoneAutoStopEnabled).
        [bool]$AutoStop = $true,
        # Folder whose Logs\ gets the runtime file (keystone-server-<pid>.json).
        [string]$RuntimeRoot
    )
    if ($DevGitHubUrl) {
        if (-not $LocalDev) { throw 'A synthetic provider (-DevGitHubUrl) is only allowed with -LocalDev.' }
        Set-KeystoneDevProvider -GitHubUrl $DevGitHubUrl
    }
    Initialize-KeystoneApp -WorkRoot $WorkRoot -StateRoot $StateRoot -LegacyStateRoot $LegacyStateRoot -WorkRootFixed:$WorkRootFixed -LocalDev:$LocalDev
    Reset-KeystonePresence -AutoStop $AutoStop
    $script:KeystoneHostLife = @{ AutoStop = $AutoStop; RuntimeFile = $null; StopEvent = $null; StopReason = $null; Pending = $null; WaitLogged = $false }
    $onReady = {
        param($Url)
        # Runtime file and stop event first: anything that sees the link can already find this host.
        if ($RuntimeRoot) {
            try { $script:KeystoneHostLife.RuntimeFile = Write-KeystoneRuntimeFile -Root $RuntimeRoot -Port (Get-KeystoneHttpPort) -Url ('http://127.0.0.1:{0}/' -f (Get-KeystoneHttpPort)) -StateRoot $StateRoot }
            catch { Write-KeystoneLog -Level WARN -Message "Runtime file not written: $($_.Exception.Message)" }
        }
        $script:KeystoneHostLife.StopEvent = New-KeystoneStopEvent
        Write-KeystoneLog -Level INFO -Message ('Web host started: PID {0}, port {1}, auto-stop {2}' -f $PID, (Get-KeystoneHttpPort), $script:KeystoneHostLife.AutoStop)
        Write-Host ''
        Write-Host '  KEYSTONE  |  Workspace' -ForegroundColor Cyan
        if ($LocalDev) { Write-Host '  [LOCAL DEV] Test mode: use fictional data only.' -ForegroundColor Yellow }
        Write-Host "  Open: $Url" -ForegroundColor Green
        Write-Host '  The link works once, for 2 minutes. Press L here for a new one. Ctrl+C stops Keystone.' -ForegroundColor DarkGray
        if ($script:KeystoneHostLife.AutoStop) {
            Write-Host '  Stops when its browser tab closes (or End session). Keep it running: --stay or KEYSTONE_AUTO_STOP=0.' -ForegroundColor DarkGray
        } else {
            Write-Host '  Keeps running after the browser tab closes. Stop: End session, Ctrl+C or Stop-Keystone.ps1.' -ForegroundColor DarkGray
        }
        if (-not $NoBrowser) {
            try { Start-Process $Url | Out-Null } catch { Write-Host 'Open the link above in Edge or Chrome.' -ForegroundColor Yellow }
        }
    }
    $onTick = {
        Update-KeystoneJobs
        Update-KeystoneHostLifecycle
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'L') {
                    [void](New-KeystoneLaunchNonce)
                    Write-Host ("  New link: {0}" -f (Get-KeystoneLaunchUrl)) -ForegroundColor Green
                }
            }
        } catch { }   # no interactive console (tests, hidden window)
    }
    try {
        Start-KeystoneHttpServer -PreferredPort $Port -UiRoot $UiRoot -OnReady $onReady -OnTick $onTick
    } finally {
        $life = $script:KeystoneHostLife
        if ($life.StopReason) {
            Write-Host ''
            Write-Host ('  ' + $life.StopReason) -ForegroundColor Yellow
            Write-KeystoneLog -Level INFO -Message ('Web host stopping: ' + $life.StopReason)
        }
        if ($life.StopEvent) { try { $life.StopEvent.Dispose() } catch { } }
        Remove-KeystoneRuntimeFile -Path $life.RuntimeFile
    }
}

function Request-KeystoneHostStop {
    <#
      Ask the host to stop once it is idle: End session, Stop-Keystone.ps1 (named
      event) and auto-stop all come here. Running background jobs (a save, a
      download) finish first; the HTTP loop then stops on the next tick.
    #>
    param([Parameter(Mandatory)][string]$Reason)
    if ($null -eq $script:KeystoneHostLife) { Stop-KeystoneHttpServer; return }
    if (-not $script:KeystoneHostLife.Pending) { $script:KeystoneHostLife.Pending = $Reason }
}

function Update-KeystoneHostLifecycle {
    # Called on the main thread between requests (OnTick), never during one.
    $life = $script:KeystoneHostLife
    if ($null -eq $life) { return }
    if (-not $life.Pending) {
        if ($life.StopEvent -and $life.StopEvent.WaitOne(0)) { $life.Pending = 'Stop requested by Stop-Keystone.ps1 or a new launch.' }
        elseif (Test-KeystoneBrowserGone) { $life.Pending = 'Browser tab closed; Keystone stops itself (KEYSTONE_AUTO_STOP=0 or --stay keeps it running).' }
    }
    if (-not $life.Pending) { return }
    if (Test-KeystoneJobsBusy) {
        if (-not $life.WaitLogged) {
            $life.WaitLogged = $true
            Write-Host '  Stopping after the running background task finishes...' -ForegroundColor DarkGray
            Write-KeystoneLog -Level INFO -Message ('Stop pending until background jobs finish: ' + $life.Pending)
        }
        return
    }
    $life.StopReason = $life.Pending
    Stop-KeystoneHttpServer
}

function Get-KeystoneHostLifecycleState {
    if ($null -eq $script:KeystoneHostLife) { return @{ autoStop = $false; stopping = $false } }
    return @{ autoStop = [bool]$script:KeystoneHostLife.AutoStop; stopping = [bool]$script:KeystoneHostLife.Pending }
}
