#Requires -Version 5.1
# Keystone browser host entry: app state + HTTP loop + job pump + console keys.

function Start-KeystoneWebHost {
    [CmdletBinding()]
    param(
        [int]$Port = 8769,
        [switch]$NoBrowser,
        [switch]$LocalDev,
        [string]$DevGitHubUrl,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$UiRoot
    )
    if ($DevGitHubUrl) {
        if (-not $LocalDev) { throw 'A synthetic provider (-DevGitHubUrl) is only allowed with -LocalDev.' }
        Set-KeystoneDevProvider -GitHubUrl $DevGitHubUrl
    }
    Initialize-KeystoneApp -WorkRoot $WorkRoot -LocalDev:$LocalDev
    $onReady = {
        param($Url)
        Write-Host ''
        Write-Host '  KEYSTONE  |  Workspace' -ForegroundColor Cyan
        if ($LocalDev) { Write-Host '  [LOCAL DEV] Test mode: use fictional data only.' -ForegroundColor Yellow }
        Write-Host "  Open: $Url" -ForegroundColor Green
        Write-Host '  The link works once, for 2 minutes. Press L here for a new one. Ctrl+C stops Keystone.' -ForegroundColor DarkGray
        if (-not $NoBrowser) {
            try { Start-Process $Url | Out-Null } catch { Write-Host 'Open the link above in Edge or Chrome.' -ForegroundColor Yellow }
        }
    }
    $onTick = {
        Update-KeystoneJobs
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
    Start-KeystoneHttpServer -PreferredPort $Port -UiRoot $UiRoot -OnReady $onReady -OnTick $onTick
}
