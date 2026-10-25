#Requires -Version 5.1
<#
.SYNOPSIS
  Keystone local browser workspace. Windows PowerShell 5.1; no git.exe or Node.
.DESCRIPTION
  Serves the UI on http://127.0.0.1:<port>/ with a TcpListener (no URL
  reservation needed). The browser gets in through a one-time launch link;
  tokens stay in this process. ARC is optional and only used when configured
  in Integrations (or KEYSTONE_ARC_PATH); its unlock happens here, before the
  server starts. Ctrl+C stops the host.
#>
[CmdletBinding()]
param(
    [ValidateRange(1025,65535)][int]$Port = 8769,
    [switch]$NoBrowser,
    [switch]$SkipArcUnlock,
    # Explicit switch only; nothing in the environment can turn this on.
    [switch]$LocalDev,
    # LocalDev only: a synthetic GitHub server (dev/fake-github.mjs), http://127.0.0.1:<port>/
    [string]$DevGitHubUrl,
    # Where workspaces go for this run (tests and LocalDev). Normally the workspace folder
    # from Settings (default %USERPROFILE%\Keystone); the saved session then lives in
    # %LOCALAPPDATA%\Keystone. With -WorkRoot both live under that folder.
    [string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
# With -WorkRoot (tests, LocalDev) every setting Keystone writes stays under that folder.
if ($WorkRoot) { Initialize-Keystone -ConfigPath (Join-Path (Join-Path (Join-Path $WorkRoot '.keystone') 'config') 'keystone-config.json') }
else { Initialize-Keystone }

if ($LocalDev) {
    Write-Host '[LOCAL DEV] ARC is not imported; no unlock prompts. Use fictional data only.' -ForegroundColor Yellow
} elseif (Test-KeystoneArcConfigured) {
    # ARC's own unlock (passphrase or CAC PIN, then authenticator), in THIS console.
    $arcState = Initialize-KeystoneArcAuthentication -SkipUnlock:$SkipArcUnlock
    if (-not $arcState.Unlocked) {
        Write-Host '[!] ARC is configured but not unlocked. Saved Keystone or environment credentials still work.' -ForegroundColor Yellow
    }
} else {
    Write-Host '[i] ARC not configured (optional). Using saved Keystone or environment credentials.' -ForegroundColor DarkGray
}

$hostArgs = @{ Port = $Port; NoBrowser = $NoBrowser; LocalDev = $LocalDev; DevGitHubUrl = $DevGitHubUrl; UiRoot = (Join-Path $root 'web') }
if ($WorkRoot) {
    $hostArgs.WorkRoot = $WorkRoot
    $hostArgs.StateRoot = Join-Path $WorkRoot '.keystone'
    $hostArgs.WorkRootFixed = $true
} else {
    $hostArgs.WorkRoot = Get-KeystoneWorkspaceRoot
    $appData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:HOME) { Join-Path $env:HOME '.local/share' } else { [IO.Path]::GetTempPath() }
    $hostArgs.StateRoot = Join-Path $appData 'Keystone'
    $hostArgs.LegacyStateRoot = Join-Path (Join-Path $root 'work') '.keystone'
}
Write-Host ("[i] Workspaces: {0}" -f $hostArgs.WorkRoot) -ForegroundColor DarkGray
Start-KeystoneWebHost @hostArgs
