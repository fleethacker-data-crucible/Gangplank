#Requires -Version 5.1
<#
.SYNOPSIS
  Gangplank local browser workspace. Windows PowerShell 5.1; no git.exe or Node.
.DESCRIPTION
  Serves the UI on http://127.0.0.1:<port>/ with a TcpListener (no URL
  reservation needed). The browser gets in through a one-time launch link;
  tokens stay in this process. Lazarette is optional and only used when configured
  in Integrations (or GANGPLANK_LAZARETTE_PATH); its unlock happens here, before the
  server starts.

  The browser tab owns the host: the page sends a heartbeat every 5 seconds and
  the host stops itself 20 seconds after the last one (5 seconds after the tab
  says it is leaving). A reload does not stop it; with several tabs open it stops
  when the last one is gone. It never stops while a background job (save,
  download, review, AI) is running. End session in the browser, Ctrl+C here, or
  Stop-Gangplank.ps1 also stop it.
.PARAMETER Stay
  Keep running after the browser tab closes. Also --stay, or GANGPLANK_AUTO_STOP=0
  (environment), or "AutoStop": false in config\gangplank-config.json.
.PARAMETER Replace
  If Gangplank is already running from this folder with the same saved session,
  stop it and start fresh without asking. Also --replace.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateRange(1025,65535)][int]$Port = 8769,
    [switch]$NoBrowser,
    [switch]$SkipLazaretteUnlock,
    # Explicit switch only; nothing in the environment can turn this on.
    [switch]$LocalDev,
    # LocalDev only: a synthetic GitHub server (dev/fake-github.mjs), http://127.0.0.1:<port>/
    [string]$DevGitHubUrl,
    # LocalDev only: a synthetic GitLab server (dev/fake-gitlab.mjs), http://127.0.0.1:<port>/
    [string]$DevGitLabUrl,
    # Where workspaces go for this run (tests and LocalDev). Normally the workspace folder
    # from Settings (default %USERPROFILE%\Gangplank); the saved session then lives in
    # %LOCALAPPDATA%\Gangplank. With -WorkRoot both live under that folder.
    [string]$WorkRoot,
    [switch]$Stay,
    [switch]$Replace,
    # Launcher-style options (--stay, --replace, --no-browser) and a bare port number,
    # so Launch-Gangplank.bat can pass everything through (-NoBrowser 19000 --stay).
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
        '^\d{4,5}$' {
            $n = [int]$a
            if ($n -lt 1025 -or $n -gt 65535) { throw "Port $a is out of range (1025-65535)." }
            $Port = $n; continue
        }
        default { Write-Warning "Ignoring unknown option $a" }
    }
}

# Where this run keeps its saved session. Two hosts with the same state folder would
# fight over it, so that is what "already running" means (tests and LocalDev use
# their own -WorkRoot and never collide with a real session).
if ($WorkRoot) {
    $stateRoot = Join-Path $WorkRoot '.gangplank'
} else {
    $appData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:HOME) { Join-Path $env:HOME '.local/share' } else { [IO.Path]::GetTempPath() }
    $stateRoot = Join-Path $appData 'Gangplank'
}

# One instance: a host still running (often a hidden window whose tab was closed)
# holds the session. Stop it before Lazarette asks for an unlock.
. (Join-Path $root 'Core\Lifecycle.ps1')
$running = @(Get-GangplankServerProcesses -Root $root -ThisCheckout -StateRoot $stateRoot)
if ($running.Count -gt 0) {
    $where = ($running | ForEach-Object { Format-GangplankServerProcess -Process $_ }) -join ', '
    Write-Host ('Gangplank is already running: ' + $where) -ForegroundColor Yellow
    $answer = 'y'
    $interactive = $true
    try { if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { $interactive = $false } } catch { $interactive = $false }
    if (-not $Replace -and $interactive) {
        try { $answer = Read-Host 'Stop it and start fresh? [Y/n]' } catch { $answer = 'n' }
    } elseif (-not $Replace) {
        Write-Host '  No console to ask in; stopping it (the default answer).' -ForegroundColor DarkGray
    }
    if ($answer -eq '' -or $answer -match '^[Yy]') {
        foreach ($p in @(Stop-GangplankServerProcesses -Root $root -ThisCheckout -StateRoot $stateRoot)) {
            Write-Host ('  Stopped Gangplank ' + (Format-GangplankServerProcess -Process $p)) -ForegroundColor DarkGray
        }
    } else {
        Write-Host 'Leaving the running Gangplank alone. Use End session in its browser tab, or Stop-Gangplank.ps1.' -ForegroundColor DarkGray
        exit 0
    }
}

# Gangplank was Keystone: carry its saved session, sealed tokens and (with -WorkRoot)
# LocalDev config forward once. Done after the single-instance check, so no Keystone
# host is still writing to the old folder; the old folder is left as it was.
$legacyStateRoot = if ($WorkRoot) { Join-Path $WorkRoot '.keystone' } else { Join-Path (Split-Path $stateRoot -Parent) 'Keystone' }
if (Copy-GangplankLegacyStateFolder -From $legacyStateRoot -To $stateRoot) {
    Write-Host ("[i] Copied your Keystone data from {0} to {1} (the original is unchanged)." -f $legacyStateRoot, $stateRoot) -ForegroundColor DarkGray
}

Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
# With -WorkRoot (tests, LocalDev) every setting Gangplank writes stays under that folder.
if ($WorkRoot) { Initialize-Gangplank -ConfigPath (Join-Path (Join-Path (Join-Path $WorkRoot '.gangplank') 'config') 'gangplank-config.json') }
else { Initialize-Gangplank }
$autoStop = Test-GangplankAutoStopEnabled -Stay:$Stay -Config (Get-GangplankConfig)

if ($LocalDev) {
    Write-Host '[LOCAL DEV] Lazarette is not imported; no unlock prompts. Use fictional data only.' -ForegroundColor Yellow
} elseif (Test-GangplankLazaretteConfigured) {
    # Lazarette's own unlock (passphrase or smart card PIN, then authenticator), in THIS console.
    $lazaretteState = Initialize-GangplankLazaretteAuthentication -SkipUnlock:$SkipLazaretteUnlock
    if (-not $lazaretteState.Unlocked) {
        Write-Host '[!] Lazarette is configured but not unlocked. Saved Gangplank or environment credentials still work.' -ForegroundColor Yellow
    }
} else {
    Write-Host '[i] Lazarette not configured (optional). Using saved Gangplank or environment credentials.' -ForegroundColor DarkGray
}

$hostArgs = @{ Port = $Port; NoBrowser = $NoBrowser; LocalDev = $LocalDev; DevGitHubUrl = $DevGitHubUrl; DevGitLabUrl = $DevGitLabUrl; UiRoot = (Join-Path $root 'web'); StateRoot = $stateRoot; AutoStop = $autoStop; RuntimeRoot = $root }
if ($WorkRoot) {
    $hostArgs.WorkRoot = $WorkRoot
    $hostArgs.WorkRootFixed = $true
} else {
    $hostArgs.WorkRoot = Get-GangplankWorkspaceRoot
    # Sessions saved by Keystone before the host refactor (<tool>\work\.keystone).
    $hostArgs.LegacyStateRoot = Join-Path (Join-Path $root 'work') '.keystone'
}
Write-Host ("[i] Workspaces: {0}" -f $hostArgs.WorkRoot) -ForegroundColor DarkGray
Start-GangplankWebHost @hostArgs
