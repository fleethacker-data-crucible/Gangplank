#Requires -Version 5.1
# The Lazarette credentials flow end to end against an in-memory stub vault: the vault is
# unlocked once at startup, tokens are read by item name, a loopback AI endpoint (the Fleet
# router) does not open the vault, and no token is written to Gangplank's credential store,
# its settings file or the saved session state. No real vault, smart card or network.
# Separate process (CI runs each suite in its own).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-vault-flow-' + [guid]::NewGuid().ToString('N'))
$names = @('LAZARETTE_PATH','GANGPLANK_LAZARETTE_PATH','GITHUB_TOKEN','GH_TOKEN','GITLAB_TOKEN',
    'GANGPLANK_FAIRLEAD_URL','GANGPLANK_FAIRLEAD_TARGET','LLM_URL','LLM_TOKEN','OPENAI_BASE_URL','OPENAI_API_KEY',
    'GANGPLANK_LAZARETTE_ITEM_GitHub')
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n,$null) }
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
try {
    $laz = Join-Path $temp 'lazarette'
    [void](New-Item -ItemType Directory -Path (Join-Path $laz 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path (Join-Path $laz 'lib') 'Lazarette.ps1'),@'
$script:StubUnlocked = $false
$script:StubRecords = @(
    [pscustomobject]@{ Service = 'github'; User = 'me'; Secret = 'fake-vault-github-token' },
    [pscustomobject]@{ Service = 'ai-api-key'; User = 'me'; Secret = 'fake-vault-ai-key' }
)
function Test-LazaretteVaultUnlocked { return $script:StubUnlocked }
function Unlock-LazaretteVaultInteractive { $global:VaultUnlockCalls += 1; $script:StubUnlocked = $true; return $true }
function Get-LazaretteItemNames {
    if (-not $script:StubUnlocked) { throw 'Lazarette vault is locked.' }
    return @($script:StubRecords | ForEach-Object { [pscustomobject]@{ Service = $_.Service; User = $_.User; Type = 'api'; Tags = '' } })
}
function Get-LazaretteSecret {
    param([Parameter(Mandatory)][string]$Service, [string]$User = '', [string]$Field = '')
    if (-not $script:StubUnlocked) { throw 'Lazarette vault is locked.' }
    $global:VaultReads += @($Service)
    $hits = @($script:StubRecords | Where-Object { $_.Service -ieq $Service })
    if ($hits.Count -ne 1) { throw "Lazarette has no single item '$Service'." }
    return [string]$hits[0].Secret
}
'@)
    $env:GANGPLANK_LAZARETTE_PATH = $laz
    $config = Join-Path $temp 'config\gangplank-config.json'
    [void](New-Item -ItemType Directory -Path (Split-Path $config) -Force)
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank -LogLevel ERROR -ConfigPath $config

    # Opt-in only, then one unlock at startup.
    $global:VaultUnlockCalls = 0; $global:VaultReads = @()
    Assert (Import-GangplankLazaretteSession -Quiet) 'The stub Lazarette should load'
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked -and $global:VaultUnlockCalls -eq 1) 'The vault is unlocked exactly once at startup'

    # Tokens are read by item name: github for GitHub. AI keys are never read from the vault.
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-vault-github-token') 'The GitHub token comes from the github item'
    Assert (@($global:VaultReads | Where-Object { $_ -eq 'github' }).Count -ge 1) 'The github item was read by name'
    Assert (@($global:VaultReads | Where-Object { $_ -eq 'ai-api-key' }).Count -eq 0) 'The ai-api-key item is never read'
    Assert ($global:VaultUnlockCalls -eq 1) 'Reading tokens never unlocks the vault again'

    # The Fairlead key comes from Credential Manager only: the vault is not opened for it.
    $before = @($global:VaultReads).Count
    Set-GangplankFairleadKeyReader -Reader { param($Target) $null }
    Assert ($null -eq (Get-GangplankFairleadKey)) 'No Credential Manager key: no key'
    Set-GangplankFairleadKeyReader -Reader $null
    Assert (@($global:VaultReads).Count -eq $before) 'Looking for the Fairlead key must not read the vault'

    # The browser-facing status lists item names, never values.
    $json = (Get-GangplankLazaretteConnectionStatus | ConvertTo-Json -Depth 6 -Compress)
    Assert ($json -notmatch 'fake-vault-') 'The connection status must not carry a secret'
    Assert ($json -match 'github') 'The connection status lists the item names'

    # Nothing is persisted: credential store, settings file and saved session state hold no token.
    & (Get-Module Gangplank) {
        param($StateRoot)
        $snapshot = @{
            Provider = 'GitHub'; BaseUrl = 'https://github.com'; ProjectPath = 'team/demo'; DefaultBranch = 'main'
            Branches = @('main'); LocalPath = $null; LastBranch = $null; BaselineSha = $null; BaselineMap = @{}
        }
        $session = New-GangplankSessionFromSnapshot -Snapshot $snapshot -Token 'fake-vault-github-token'
        Save-GangplankSessionState -StateRoot $StateRoot -Session $session
    } (Join-Path $temp 'state')
    $leaks = @()
    foreach ($dir in @((Join-Path $temp 'state'), (Split-Path $config), $script:GangplankTestStoreDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
            if ((Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue) -match 'fake-vault-') { $leaks += $f.FullName }
        }
    }
    Assert ($leaks.Count -eq 0) ('Vault tokens must not be written to disk by Gangplank: ' + ($leaks -join ', '))
    Assert (Test-Path -LiteralPath (Join-Path $temp 'state')) 'The session state was saved (so the scan above looked at a real file)'

    Write-Host 'Lazarette vault flow (unlock once, read by item name, router skips the vault, nothing persisted) passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
