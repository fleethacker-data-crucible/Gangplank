#Requires -Version 5.1
<#
.SYNOPSIS
  Stops every running Keystone browser host on this machine.
.DESCRIPTION
  Keystone normally stops itself shortly after its browser tab closes, or from
  End session in the browser. This is the fallback, for example when the host
  runs in a hidden window. It reads the runtime files the host writes under
  Logs\ (keystone-server-<pid>.json), then looks for any PowerShell still running
  Start-KeystoneWeb.ps1 (from any folder), and stops them. Each host is asked to
  stop cleanly first, so a save in progress finishes; after 30 seconds it is
  killed. Stale runtime files are removed. No PIDs needed.
.PARAMETER Quiet
  Print nothing unless something was stopped.
.PARAMETER ThisFolderOnly
  Only stop hosts started from this Keystone folder.
.PARAMETER WorkRoot
  Only stop hosts started with this -WorkRoot (tests and LocalDev use their own
  folder, so they never stop the Keystone you are working in).
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Keystone.ps1
#>
[CmdletBinding()]
param([switch]$Quiet, [switch]$ThisFolderOnly, [string]$WorkRoot)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'Core\Lifecycle.ps1')
$stateRoot = $null
if ($WorkRoot) { $stateRoot = Join-Path $WorkRoot '.keystone' }
$stopped = @(Stop-KeystoneServerProcesses -Root $root -ThisCheckout:$ThisFolderOnly -StateRoot $stateRoot)
if ($stopped.Count -gt 0) {
    foreach ($p in $stopped) { Write-Host ('Stopped Keystone ' + (Format-KeystoneServerProcess -Process $p) + '.') -ForegroundColor Yellow }
} elseif (-not $Quiet) {
    Write-Host 'No Keystone host is running.' -ForegroundColor DarkGray
}
