#Requires -Version 5.1
<#
.SYNOPSIS
  Keystone was renamed to Gangplank: forwards to Stop-Gangplank.ps1.
.DESCRIPTION
  Kept so scripts, shortcuts and notes that call Stop-Keystone.ps1 keep working.
  Stop-Gangplank.ps1 also finds and stops hosts started before the rename
  (Start-KeystoneWeb.ps1, Logs\keystone-server-<pid>.json). May be removed in a
  later release.
#>
[CmdletBinding()]
param([switch]$Quiet, [switch]$ThisFolderOnly, [string]$WorkRoot)
& (Join-Path $PSScriptRoot 'Stop-Gangplank.ps1') @PSBoundParameters
