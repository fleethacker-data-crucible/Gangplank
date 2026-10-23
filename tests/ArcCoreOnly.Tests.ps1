#Requires -Version 5.1
# Separate-process smoke test for an older ARC with core vault APIs but no STARK.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-arc-core-' + [guid]::NewGuid().ToString('N'))
$oldArc = $env:ARC_PATH
$oldToken = $env:GITHUB_TOKEN
function Assert([bool]$ok,[string]$message) { if (-not $ok) { throw "FAILED: $message" } }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    $fake = @'
$script:PmState = @{ VaultUnlocked = $false }
$script:Rows = New-Object System.Collections.ArrayList
[void]$script:Rows.Add([pscustomobject]@{ Service = 'another-item'; Secret = 'fixture:other' })
[void]$script:Rows.Add([pscustomobject]@{ Service = 'github'; Secret = 'fixture:core-github-test-token' })
function Ensure-VaultUnlocked {
    $global:FakeCoreUnlockCalls += 1
    $script:PmState.VaultUnlocked = $true
    return $true
}
function Get-LiveVault { return ,$script:Rows }
function Find-VaultRows {
    param([string]$Name)
    return ,$script:Rows
}
function Unprotect-SecretText {
    param([string]$Protected)
    if (-not $script:PmState.VaultUnlocked) { throw 'Locked' }
    if (-not $Protected.StartsWith('fixture:')) { throw 'Invalid fixture payload' }
    return $Protected.Substring(8)
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'pm.ps1'),$fake)
    $env:ARC_PATH = $temp
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    $global:FakeCoreUnlockCalls = 0
    Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
    Initialize-Keystone
    Assert (Import-KeystoneArcSession -Quiet) 'Core ARC should load without optional STARK helper'
    Assert (-not (Test-KeystoneArcVaultUnlocked)) 'Core ARC should start locked'
    Assert (-not (Get-KeystoneArcSecretByName -ServiceName github)) 'No credential read while locked'
    Assert ($global:FakeCoreUnlockCalls -eq 0) 'Request-side lookup triggered unlock'
    $result = Initialize-KeystoneArcAuthentication -Quiet
    Assert ($result.Unlocked) 'Core ARC should unlock at startup'
    Assert ($global:FakeCoreUnlockCalls -eq 1) 'Core ARC should authenticate once'
    $names = @(Get-KeystoneArcServiceNames)
    Assert ($names -contains 'github') 'Core catalog missing github'
    Assert ($names -contains 'another-item') 'Core catalog missing second item'
    $token = Get-KeystoneArcSecretByName -ServiceName github
    Assert ($token -eq 'core-github-test-token') 'Core ARC decryption failed'
    Assert ((Get-KeystoneToken -Provider GitHub) -eq 'core-github-test-token') 'Provider did not use core ARC token'
    $status = Get-KeystoneArcConnectionStatus
    Assert $status.arcLoaded 'Status says core ARC not loaded'
    Assert $status.arcUnlocked 'Status says core ARC locked'
    Assert ($status.itemNames -contains 'github') 'Browser catalog unavailable'
    $json = $status | ConvertTo-Json -Depth 8
    Assert ($json -notmatch 'core-github-test-token') 'Token leaked in browser metadata'
    Assert ($global:FakeCoreUnlockCalls -eq 1) 'HTTP-safe metadata triggered unlock'
    Write-Host 'Core-only ARC fallback and vault row unwrap checks passed.' -ForegroundColor Green
} finally {
    if ($oldArc) { $env:ARC_PATH = $oldArc } else { Remove-Item Env:ARC_PATH -ErrorAction SilentlyContinue }
    if ($oldToken) { $env:GITHUB_TOKEN = $oldToken } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
