#Requires -Version 5.1
# Offline Lazarette bridge contract test (Lazarette docs/INTEGRATION.md). Uses a stub
# lib\Arc.ps1 with an in-memory vault: no secrets, smart card, network or real vault.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-contract5-' + [guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($n in @('ARC_PATH','ARC_ROOT','ARC_HOME','GANGPLANK_LAZARETTE_PATH','GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_GITLAB_HOST','GANGPLANK_GITLAB_ALLOWED_HOSTS','GANGPLANK_LAZARETTE_ITEM_GitHub','ARC_ITEM_GitHub','CASCADE_ARC_ITEM_GitHub')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
try {
    # A folder with only Lazarette's throwing pm.ps1 stub is not a Lazarette install.
    $stubOnly = Join-Path $temp 'stub-only'
    [void](New-Item -ItemType Directory -Path $stubOnly -Force)
    [IO.File]::WriteAllText((Join-Path $stubOnly 'pm.ps1'),"throw ('ARC 5 no longer provides pm.ps1. Load lib\Arc.ps1')")

    $laz = Join-Path $temp 'arc'
    [void](New-Item -ItemType Directory -Path (Join-Path $laz 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path $laz 'pm.ps1'),"throw ('ARC 5 no longer provides pm.ps1. Load lib\Arc.ps1')")
    [IO.File]::WriteAllText((Join-Path (Join-Path $laz 'lib') 'Arc.ps1'),@'
$script:StubUnlocked = $false
$script:StubRecords = @(
    [pscustomobject]@{ Service = 'github'; User = 'me'; Secret = 'fake-lazarette5-github-token' },
    [pscustomobject]@{ Service = 'legacy-gitlab-item'; User = 'me'; Secret = 'fake-lazarette5-gitlab-token' },
    [pscustomobject]@{ Service = 'twice'; User = 'a'; Secret = 'one' },
    [pscustomobject]@{ Service = 'twice'; User = 'b'; Secret = 'two' }
)
function Test-ArcVaultUnlocked { return $script:StubUnlocked }
function Unlock-ArcVaultInteractive { $global:LazaretteStubUnlockCalls += 1; $script:StubUnlocked = $true; return $true }
function Lock-ArcVault { $script:StubUnlocked = $false }
function Get-ArcItemNames {
    if (-not $script:StubUnlocked) { throw 'Lazarette vault is locked.' }
    return @($script:StubRecords | ForEach-Object { [pscustomobject]@{ Service = $_.Service; User = $_.User; Type = 'api'; Tags = '' } })
}
function Get-ArcSecret {
    param([Parameter(Mandatory)][string]$Service, [string]$User = '', [string]$Field = '')
    if (-not $script:StubUnlocked) { throw 'Lazarette vault is locked. Call Unlock-ArcVaultInteractive first.' }
    $hits = @($script:StubRecords | Where-Object { $_.Service -ieq $Service })
    if ($hits.Count -eq 0) { throw "Lazarette has no item '$Service'." }
    if ($hits.Count -gt 1) { throw "Lazarette has $($hits.Count) items named '$Service'; pass -User to choose one." }
    return [string]$hits[0].Secret
}
'@)

    $env:GANGPLANK_LAZARETTE_PATH = $stubOnly
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    # The stub vault holds the GitLab token under the legacy default item name only.
    $legacyGitLabItem = & (Get-Module Gangplank) { Get-GangplankLegacyItemName -Purpose GitLab }
    Assert ([bool]$legacyGitLabItem) 'A legacy GitLab item name should be defined'
    $arcStub = Join-Path (Join-Path $laz 'lib') 'Arc.ps1'
    [IO.File]::WriteAllText($arcStub,[IO.File]::ReadAllText($arcStub).Replace('legacy-gitlab-item',$legacyGitLabItem))
    Initialize-Gangplank -LogLevel ERROR
    $env:ARC_HOME = $null
    Assert ((Get-GangplankLazaretteFlavor -LazaretteRoot $stubOnly) -eq '') 'The Lazarette pm.ps1 stub must not be treated as ARC 3/4'
    Assert ((Get-GangplankLazaretteFlavor -LazaretteRoot $laz) -eq 'v5') 'lib\Arc.ps1 must identify Lazarette'

    $env:GANGPLANK_LAZARETTE_PATH = $laz
    Assert ((Find-GangplankLazaretteRoot) -eq [IO.Path]::GetFullPath($laz)) 'Lazarette root not discovered'
    Assert (Import-GangplankLazaretteSession -Quiet) 'Lazarette engine should load'
    Assert (-not (Test-GangplankLazaretteVaultUnlocked)) 'Vault starts locked'
    $locked = Get-GangplankLazaretteConnectionStatus
    Assert ($locked.lazaretteLoaded -and -not $locked.lazaretteUnlocked) 'Locked state not reported'
    Assert ($locked.lazaretteVersion -eq '5') 'Lazarette version should be reported as 5'
    Assert (@($locked.itemNames).Count -eq 0) 'No names may be listed while locked'
    $lockedError = ''
    try { [void](Get-GangplankToken -Provider GitHub) } catch { $lockedError = $_.Exception.Message }
    Assert ($lockedError -match '^ARC_LOCKED\|') "Locked vault must report ARC_LOCKED, got: $lockedError"

    $global:LazaretteStubUnlockCalls = 0
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked) 'Initialize must unlock through Unlock-ArcVaultInteractive'
    Assert ($global:LazaretteStubUnlockCalls -eq 1) 'Lazarette unlock should be called exactly once'
    $again = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($again.Unlocked -and $global:LazaretteStubUnlockCalls -eq 1) 'An open vault must not be unlocked twice'

    $status = Get-GangplankLazaretteConnectionStatus
    Assert ($status.lazaretteUnlocked) 'Unlocked state not reported'
    Assert ((@($status.itemNames) -join ',') -eq ('github,' + $legacyGitLabItem + ',twice')) ('Item names wrong: ' + (@($status.itemNames) -join ','))
    Assert ((Get-GangplankLazaretteItemName -Provider GitLab) -eq 'gitlab') 'The default GitLab item name should be gitlab'
    $json = $status | ConvertTo-Json -Depth 6
    Assert ($json -notmatch 'fake-lazarette5') 'Connection status leaked a secret'

    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lazarette5-github-token') 'GitHub token not read via Get-ArcSecret'
    # The legacy GitLab item is never sent unless its host was explicitly configured.
    $noLegacy = ''
    try { [void](Get-GangplankToken -Provider GitLab -TargetHost 'gitlab.example.org') } catch { $noLegacy = $_.Exception.Message }
    Assert ($noLegacy -match '^ARC_ITEM_MISSING\|') "No configured GitLab host: the legacy item must not be read, got: $noLegacy"
    $env:GANGPLANK_GITLAB_ALLOWED_HOSTS = 'other.example.org'
    $env:GANGPLANK_GITLAB_HOST = 'gitlab.example.org'
    $noLegacy = ''
    try { [void](Get-GangplankToken -Provider GitLab -TargetHost 'other.example.org') } catch { $noLegacy = $_.Exception.Message }
    Assert ($noLegacy -match '^ARC_ITEM_MISSING\|') "An allowlisted but not configured host must not get the legacy item, got: $noLegacy"
    Assert ((Get-GangplankToken -Provider GitLab -TargetHost 'gitlab.example.org') -eq 'fake-lazarette5-gitlab-token') 'GitLab token not read from the legacy default item for the configured host'
    $env:GANGPLANK_GITLAB_HOST = $null
    $env:GANGPLANK_GITLAB_ALLOWED_HOSTS = $null
    Assert ($null -eq (Get-GangplankLazaretteSecretByName -ServiceName 'twice')) 'Ambiguous items must not return a secret'
    Assert ((Get-GangplankLazaretteConnectionStatus).message -ne $null) 'Status must still render after an ambiguous lookup'

    $env:GANGPLANK_LAZARETTE_ITEM_GitHub = 'absent'
    $missing = ''
    try { [void](Get-GangplankToken -Provider GitHub) } catch { $missing = $_.Exception.Message }
    Assert ($missing -match '^ARC_ITEM_MISSING\|') "Unmapped item must report ARC_ITEM_MISSING, got: $missing"
    $env:GANGPLANK_LAZARETTE_ITEM_GitHub = $null

    $env:GITHUB_TOKEN = 'env-wins'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'env-wins') 'Approved environment credential should take precedence'
    Write-Host 'Gangplank Lazarette bridge contract passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
