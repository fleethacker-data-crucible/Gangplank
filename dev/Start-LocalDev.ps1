#Requires -Version 5.1
<#
.SYNOPSIS
  Keystone LocalDev: the real host against a synthetic GitHub (dev/fake-github.mjs).
.DESCRIPTION
  Development PCs only. Starts the synthetic server with Node (if available),
  sets a fake GITHUB_TOKEN for this process only, and runs Start-KeystoneWeb.ps1
  -LocalDev -DevGitHubUrl. Without Node, the host starts in LocalDev with no
  provider. Fictional data only; never real credentials or work data.
#>
[CmdletBinding()]
param([int]$Port = 8769,[int]$FakePort = 8791,[switch]$NoBrowser,[switch]$NoFake)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root 'work-localdev'
$fake = $null
$hostArgs = @{ LocalDev = $true; Port = $Port; NoBrowser = $NoBrowser; WorkRoot = $work }
try {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $NoFake -and $node) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $node.Source
        $psi.Arguments = ('"{0}" {1}' -f (Join-Path $PSScriptRoot 'fake-github.mjs'), $FakePort)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $fake = [Diagnostics.Process]::Start($psi)
        $line = $fake.StandardOutput.ReadLine()
        $info = $line | ConvertFrom-Json
        $env:GITHUB_TOKEN = [string]$info.token     # this process only; synthetic
        $hostArgs.DevGitHubUrl = ([string]$info.url).TrimEnd('/') + '/'
        Write-Host "[LOCAL DEV] Synthetic GitHub at $($info.url) (repo keystone-demo/sample)." -ForegroundColor Yellow
    } elseif (-not $NoFake) {
        Write-Host '[LOCAL DEV] Node.js not found: starting without the synthetic GitHub.' -ForegroundColor Yellow
    }
    & (Join-Path $root 'Start-KeystoneWeb.ps1') @hostArgs
} finally {
    if ($fake -and -not $fake.HasExited) { try { $fake.Kill() } catch { } }
}
