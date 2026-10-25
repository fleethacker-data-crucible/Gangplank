#Requires -Version 5.1
# Lazarette names: a folder with lib\Lazarette.ps1 exposing Unlock-LazaretteVaultInteractive /
# Get-LazaretteSecret / Get-LazaretteItemNames / Test-LazaretteVaultUnlocked, plus the old
# ARC names that must NOT be used when the Lazarette ones exist. Also the pre-rename
# KEYSTONE_ARC_PATH / KEYSTONE_ARC_ITEM_* opt-ins. Separate process (CI runs each suite in its own).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-names-' + [guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($n in @('ARC_PATH','ARC_ROOT','ARC_HOME','LAZARETTE_PATH','GANGPLANK_LAZARETTE_PATH','KEYSTONE_ARC_PATH','GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_LAZARETTE_ITEM_GitHub','KEYSTONE_ARC_ITEM_GitHub','ARC_ITEM_GitHub','CASCADE_ARC_ITEM_GitHub')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
try {
    $laz = Join-Path $temp 'lazarette'
    [void](New-Item -ItemType Directory -Path (Join-Path $laz 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path $laz 'pm.ps1'),"throw ('Lazarette no longer provides pm.ps1. Load lib\Lazarette.ps1')")
    [IO.File]::WriteAllText((Join-Path (Join-Path $laz 'lib') 'Lazarette.ps1'),@'
$script:StubUnlocked = $false
$script:StubRecords = @(
    [pscustomobject]@{ Service = 'github'; User = 'me'; Secret = 'fake-lazarette-github-token' },
    [pscustomobject]@{ Service = 'alt-gh'; User = 'me'; Secret = 'fake-lazarette-alt-token' }
)
function Test-LazaretteVaultUnlocked { return $script:StubUnlocked }
function Unlock-LazaretteVaultInteractive { $global:LazUnlockCalls += 1; $script:StubUnlocked = $true; return $true }
function Get-LazaretteItemNames {
    if (-not $script:StubUnlocked) { throw 'Lazarette vault is locked.' }
    return @($script:StubRecords | ForEach-Object { [pscustomobject]@{ Service = $_.Service; User = $_.User; Type = 'api'; Tags = '' } })
}
function Get-LazaretteSecret {
    param([Parameter(Mandatory)][string]$Service, [string]$User = '', [string]$Field = '')
    if (-not $script:StubUnlocked) { throw 'Lazarette vault is locked.' }
    $hits = @($script:StubRecords | Where-Object { $_.Service -ieq $Service })
    if ($hits.Count -ne 1) { throw "Lazarette has no single item '$Service'." }
    return [string]$hits[0].Secret
}
# Former names, kept by Lazarette as aliases. Gangplank must prefer the Lazarette names.
function Unlock-ArcVaultInteractive { $global:ArcNameCalls += 1; $script:StubUnlocked = $true; return $true }
function Get-ArcSecret { param([string]$Service) $global:ArcNameCalls += 1; return 'from-get-arcsecret' }
function Get-ArcItemNames { $global:ArcNameCalls += 1; return @() }
function Test-ArcVaultUnlocked { $global:ArcNameCalls += 1; return $script:StubUnlocked }
'@)
    # Pre-rename environment opt-in still works.
    $env:KEYSTONE_ARC_PATH = $laz
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank -LogLevel ERROR
    Assert ((Get-GangplankLazaretteFlavor -LazaretteRoot $laz) -eq 'v5') 'lib\Lazarette.ps1 must identify Lazarette'
    Assert ((Find-GangplankLazaretteRoot) -eq [IO.Path]::GetFullPath($laz)) 'KEYSTONE_ARC_PATH must still enable Lazarette'
    # The new name wins over the old one.
    $env:GANGPLANK_LAZARETTE_PATH = Join-Path $temp 'nowhere'
    Assert ((Get-GangplankConfiguredLazarettePath) -eq $env:GANGPLANK_LAZARETTE_PATH) 'GANGPLANK_LAZARETTE_PATH must win over KEYSTONE_ARC_PATH'
    $env:GANGPLANK_LAZARETTE_PATH = $laz
    # Generic names never enable it (opt-in per app).
    $env:KEYSTONE_ARC_PATH = $null; $env:GANGPLANK_LAZARETTE_PATH = $null
    $env:LAZARETTE_PATH = $laz; $env:ARC_PATH = $laz
    Assert (-not (Test-GangplankLazaretteConfigured)) 'LAZARETTE_PATH / ARC_PATH must not enable Lazarette'
    $env:LAZARETTE_PATH = $null; $env:ARC_PATH = $null
    $env:GANGPLANK_LAZARETTE_PATH = $laz

    $global:LazUnlockCalls = 0; $global:ArcNameCalls = 0
    Assert (Import-GangplankLazaretteSession -Quiet) 'Lazarette engine should load from lib\Lazarette.ps1'
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked -and $global:LazUnlockCalls -eq 1) 'Unlock must go through Unlock-LazaretteVaultInteractive'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette-github-token') 'Token must be read with Get-LazaretteSecret'
    Assert ((@((Get-GangplankLazaretteConnectionStatus).itemNames) -join ',') -eq 'alt-gh,github') 'Names must come from Get-LazaretteItemNames'
    Assert ($global:ArcNameCalls -eq 0) 'The former ARC names must not be called when the Lazarette names exist'
    # Item-name overrides: new name first, pre-rename name as fallback.
    $env:KEYSTONE_ARC_ITEM_GitHub = 'alt-gh'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette-alt-token') 'KEYSTONE_ARC_ITEM_GitHub must still map the item'
    $env:GANGPLANK_LAZARETTE_ITEM_GitHub = 'github'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette-github-token') 'GANGPLANK_LAZARETTE_ITEM_GitHub must win'
    Write-Host 'Gangplank Lazarette names, lib\Lazarette.ps1 and pre-rename opt-ins passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
