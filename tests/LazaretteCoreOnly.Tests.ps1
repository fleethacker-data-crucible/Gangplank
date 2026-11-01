#Requires -Version 5.1
# Separate-process test: a Lazarette whose loader lacks the integration functions is reported,
# and Gangplank never falls back to another loader, another API or a pm.ps1.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-core-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:GANGPLANK_LAZARETTE_PATH
$oldToken = $env:GITHUB_TOKEN
function Assert([bool]$ok,[string]$message) { if (-not $ok) { throw "FAILED: $message" } }
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $temp 'lib') -Force)
    # Only some of the functions exist, plus a pm.ps1 and a stray loader that must be ignored.
    [IO.File]::WriteAllText((Join-Path (Join-Path $temp 'lib') 'Lazarette.ps1'),@'
function Test-LazaretteVaultUnlocked { return $false }
function Get-LazaretteItemNames { return @() }
'@)
    [IO.File]::WriteAllText((Join-Path $temp 'pm.ps1'),"function Ensure-VaultUnlocked { `$global:FakePmCalls += 1; return `$true }")
    $env:GANGPLANK_LAZARETTE_PATH = $temp
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    $global:FakePmCalls = 0
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank
    Assert (Test-GangplankLazaretteFolder -LazaretteRoot $temp) 'lib\Lazarette.ps1 identifies the folder'
    Assert (-not (Import-GangplankLazaretteSession -Quiet)) 'An engine without all integration functions must be rejected'
    $status = Get-GangplankLazaretteConnectionStatus
    Assert ($status.code -eq 'LAZARETTE_HELPERS_UNAVAILABLE') "Missing functions must be diagnosed, got: $($status.code)"
    Assert (-not $status.lazaretteLoaded) 'Status must say Lazarette is not loaded'
    Assert ($status.message -match 'Unlock-LazaretteVaultInteractive') 'The message must name the missing functions'
    Assert (-not (Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)) 'pm.ps1 must never be loaded'
    $result = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert (-not $result.Unlocked) 'Nothing may unlock'
    Assert ($global:FakePmCalls -eq 0) 'No other unlock path may be called'
    Assert (-not (Get-GangplankLazaretteSecretByName -ServiceName github)) 'No credential read without the engine'
    $json = $status | ConvertTo-Json -Depth 8
    Assert ($json -notmatch 'test-token') 'No token in browser metadata'
    Write-Host 'Incomplete Lazarette engine is reported and nothing falls back.' -ForegroundColor Green
} finally {
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    if ($oldPath) { $env:GANGPLANK_LAZARETTE_PATH = $oldPath } else { Remove-Item Env:GANGPLANK_LAZARETTE_PATH -ErrorAction SilentlyContinue }
    if ($oldToken) { $env:GITHUB_TOKEN = $oldToken } else { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
