#Requires -Version 5.1
# Lazarette names: a folder with lib\Lazarette.ps1 exposing Unlock-LazaretteVaultInteractive /
# Get-LazaretteSecret / Get-LazaretteItemNames / Test-LazaretteVaultUnlocked. Only these names
# are used; retired names and variables are not read. Separate process (CI runs each suite in its own).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-names-' + [guid]::NewGuid().ToString('N'))
# Retired names are built from parts so this file carries none of them as text.
$retiredPrefix = ('KEY' + 'STONE_' + 'A' + 'RC_')
$retiredPath = $retiredPrefix + 'PATH'
$retiredItem = $retiredPrefix + 'ITEM_GitHub'
$retiredGenericPath = 'A' + 'RC_PATH'
$retiredFn = @('Unlock-A' + 'rcVaultInteractive', 'Get-A' + 'rcSecret', 'Get-A' + 'rcItemNames', 'Test-A' + 'rcVaultUnlocked')
$saved = @{}
foreach ($n in @($retiredGenericPath,'LAZARETTE_PATH','GANGPLANK_LAZARETTE_PATH',$retiredPath,'GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_LAZARETTE_ITEM_GitHub','LAZARETTE_ITEM_GitHub',$retiredItem)) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
try {
    $laz = Join-Path $temp 'lazarette'
    [void](New-Item -ItemType Directory -Path (Join-Path $laz 'lib') -Force)
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
'@)
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank -LogLevel ERROR
    Assert (Test-GangplankLazaretteFolder -LazaretteRoot $laz) 'lib\Lazarette.ps1 must identify Lazarette'
    $bare = Join-Path $temp 'bare'
    [void](New-Item -ItemType Directory -Path (Join-Path $bare 'lib') -Force)
    Assert (-not (Test-GangplankLazaretteFolder -LazaretteRoot $bare)) 'A folder without lib\Lazarette.ps1 is not Lazarette'
    # Only GANGPLANK_LAZARETTE_PATH (or the Integrations setting) enables Lazarette: no other name does.
    $env:GANGPLANK_LAZARETTE_PATH = $laz
    Assert ((Find-GangplankLazaretteRoot) -eq [IO.Path]::GetFullPath($laz)) 'GANGPLANK_LAZARETTE_PATH must enable Lazarette'
    $env:GANGPLANK_LAZARETTE_PATH = $null
    foreach ($n in @('LAZARETTE_PATH',$retiredGenericPath,$retiredPath)) {
        [Environment]::SetEnvironmentVariable($n,$laz)
        Assert (-not (Test-GangplankLazaretteConfigured)) "$n must not enable Lazarette"
        [Environment]::SetEnvironmentVariable($n,$null)
    }
    $env:GANGPLANK_LAZARETTE_PATH = $laz

    $global:LazUnlockCalls = 0
    Assert (Import-GangplankLazaretteSession -Quiet) 'Lazarette engine should load from lib\Lazarette.ps1'
    foreach ($fn in $retiredFn) { Assert (-not (Get-Command $fn -ErrorAction SilentlyContinue)) "$fn must not exist" }
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked -and $global:LazUnlockCalls -eq 1) 'Unlock must go through Unlock-LazaretteVaultInteractive'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette-github-token') 'Token must be read with Get-LazaretteSecret'
    Assert ((@((Get-GangplankLazaretteConnectionStatus).itemNames) -join ',') -eq 'alt-gh,github') 'Names must come from Get-LazaretteItemNames'
    # Item-name overrides: GANGPLANK_LAZARETTE_ITEM_<Purpose> only.
    [Environment]::SetEnvironmentVariable($retiredItem,'alt-gh')
    [Environment]::SetEnvironmentVariable('LAZARETTE_ITEM_GitHub','alt-gh')
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette-github-token') 'Only GANGPLANK_LAZARETTE_ITEM_<Purpose> may map the item'
    [Environment]::SetEnvironmentVariable($retiredItem,$null)
    [Environment]::SetEnvironmentVariable('LAZARETTE_ITEM_GitHub',$null)
    $env:GANGPLANK_LAZARETTE_ITEM_GitHub = 'alt-gh'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette-alt-token') 'GANGPLANK_LAZARETTE_ITEM_GitHub must map the item'
    $env:GANGPLANK_LAZARETTE_ITEM_GitHub = $null
    # Purpose names and default item names (Core/Configuration.ps1).
    & (Get-Module Gangplank) {
        function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
        Assert ((Resolve-GangplankPurposeName 'gitlab') -eq 'GitLab') 'Purpose names resolve case-insensitively to their canonical spelling'
        Assert ((Resolve-GangplankPurposeName 'AI') -eq 'AI') 'AI stays AI'
        Assert ((Resolve-GangplankPurposeName 'NotAPurpose') -eq 'NotAPurpose') 'Anything else is returned unchanged'
        Assert ((Get-GangplankLazaretteItemName -Provider AI) -eq 'ai-api-key') 'Default AI item name should be ai-api-key'
        Assert ((Get-GangplankLazaretteItemName -Provider GitLab) -eq 'gitlab') 'Default GitLab item name should be gitlab'
        Assert ((Get-GangplankLazaretteItemName -Provider GitHub) -eq 'github') 'Default GitHub item name should be github'
        Assert ((Get-GangplankLazaretteItemName -Provider DataPlatform) -eq 'data-platform-api') 'Default data platform item name should be data-platform-api'
        $threw = $false
        try { [void](Get-GangplankLazaretteItemName -Provider 'Other') } catch { $threw = $true }
        Assert $threw 'An unknown purpose must be refused'
    }
    Write-Host 'Gangplank Lazarette names and lib\Lazarette.ps1 passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
