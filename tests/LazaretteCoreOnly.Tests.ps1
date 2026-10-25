#Requires -Version 5.1
# Separate-process smoke test for an older Lazarette with core vault APIs but no STARK.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-arc-core-' + [guid]::NewGuid().ToString('N'))
$oldArc = $env:GANGPLANK_LAZARETTE_PATH
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
    $env:GANGPLANK_LAZARETTE_PATH = $temp
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    $global:FakeCoreUnlockCalls = 0
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank
    Assert (Import-GangplankLazaretteSession -Quiet) 'Core Lazarette should load without optional STARK helper'
    Assert (-not (Test-GangplankLazaretteVaultUnlocked)) 'Core Lazarette should start locked'
    Assert (-not (Get-GangplankLazaretteSecretByName -ServiceName github)) 'No credential read while locked'
    Assert ($global:FakeCoreUnlockCalls -eq 0) 'Request-side lookup triggered unlock'
    $result = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($result.Unlocked) 'Core Lazarette should unlock at startup'
    Assert ($global:FakeCoreUnlockCalls -eq 1) 'Core Lazarette should authenticate once'
    $names = @(Get-GangplankLazaretteServiceNames)
    Assert ($names -contains 'github') 'Core catalog missing github'
    Assert ($names -contains 'another-item') 'Core catalog missing second item'
    $token = Get-GangplankLazaretteSecretByName -ServiceName github
    Assert ($token -eq 'core-github-test-token') 'Core Lazarette decryption failed'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'core-github-test-token') 'Provider did not use core Lazarette token'
    $status = Get-GangplankLazaretteConnectionStatus
    Assert $status.arcLoaded 'Status says core Lazarette not loaded'
    Assert $status.arcUnlocked 'Status says core Lazarette locked'
    Assert ($status.itemNames -contains 'github') 'Browser catalog unavailable'
    $json = $status | ConvertTo-Json -Depth 8
    Assert ($json -notmatch 'core-github-test-token') 'Token leaked in browser metadata'
    Assert ($global:FakeCoreUnlockCalls -eq 1) 'HTTP-safe metadata triggered unlock'
    Write-Host 'Core-only Lazarette fallback and vault row unwrap checks passed.' -ForegroundColor Green
} finally {
    if ($oldArc) { $env:GANGPLANK_LAZARETTE_PATH = $oldArc } else { Remove-Item Env:GANGPLANK_LAZARETTE_PATH -ErrorAction SilentlyContinue }
    if ($oldToken) { $env:GITHUB_TOKEN = $oldToken } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
