#Requires -Version 5.1
# Offline ARC 5 bridge contract test (ARC docs/INTEGRATION.md). Uses a stub
# lib\Arc.ps1 with an in-memory vault: no secrets, CAC, network or real vault.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-arc5-' + [guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($n in @('ARC_PATH','ARC_ROOT','ARC_HOME','KEYSTONE_ARC_PATH','GITHUB_TOKEN','GITLAB_TOKEN','KEYSTONE_ARC_ITEM_GitHub','ARC_ITEM_GitHub','CASCADE_ARC_ITEM_GitHub')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
try {
    # A folder with only ARC 5's throwing pm.ps1 stub is not an ARC install.
    $stubOnly = Join-Path $temp 'stub-only'
    [void](New-Item -ItemType Directory -Path $stubOnly -Force)
    [IO.File]::WriteAllText((Join-Path $stubOnly 'pm.ps1'),"throw ('ARC 5 no longer provides pm.ps1. Load lib\Arc.ps1')")

    $arc = Join-Path $temp 'arc'
    [void](New-Item -ItemType Directory -Path (Join-Path $arc 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path $arc 'pm.ps1'),"throw ('ARC 5 no longer provides pm.ps1. Load lib\Arc.ps1')")
    [IO.File]::WriteAllText((Join-Path (Join-Path $arc 'lib') 'Arc.ps1'),@'
$script:StubUnlocked = $false
$script:StubRecords = @(
    [pscustomobject]@{ Service = 'github'; User = 'me'; Secret = 'fake-arc5-github-token' },
    [pscustomobject]@{ Service = 'gitmil'; User = 'me'; Secret = 'fake-arc5-gitlab-token' },
    [pscustomobject]@{ Service = 'twice'; User = 'a'; Secret = 'one' },
    [pscustomobject]@{ Service = 'twice'; User = 'b'; Secret = 'two' }
)
function Test-ArcVaultUnlocked { return $script:StubUnlocked }
function Unlock-ArcVaultInteractive { $global:Arc5StubUnlockCalls += 1; $script:StubUnlocked = $true; return $true }
function Lock-ArcVault { $script:StubUnlocked = $false }
function Get-ArcItemNames {
    if (-not $script:StubUnlocked) { throw 'ARC vault is locked.' }
    return @($script:StubRecords | ForEach-Object { [pscustomobject]@{ Service = $_.Service; User = $_.User; Type = 'api'; Tags = '' } })
}
function Get-ArcSecret {
    param([Parameter(Mandatory)][string]$Service, [string]$User = '', [string]$Field = '')
    if (-not $script:StubUnlocked) { throw 'ARC vault is locked. Call Unlock-ArcVaultInteractive first.' }
    $hits = @($script:StubRecords | Where-Object { $_.Service -ieq $Service })
    if ($hits.Count -eq 0) { throw "ARC has no item '$Service'." }
    if ($hits.Count -gt 1) { throw "ARC has $($hits.Count) items named '$Service'; pass -User to choose one." }
    return [string]$hits[0].Secret
}
'@)

    $env:KEYSTONE_ARC_PATH = $stubOnly
    Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
    Initialize-Keystone -LogLevel ERROR
    $env:ARC_HOME = $null
    Assert ((Get-KeystoneArcFlavor -ArcRoot $stubOnly) -eq '') 'The ARC 5 pm.ps1 stub must not be treated as ARC 3/4'
    Assert ((Get-KeystoneArcFlavor -ArcRoot $arc) -eq 'v5') 'lib\Arc.ps1 must identify ARC 5'

    $env:KEYSTONE_ARC_PATH = $arc
    Assert ((Find-KeystoneArcRoot) -eq [IO.Path]::GetFullPath($arc)) 'ARC 5 root not discovered'
    Assert (Import-KeystoneArcSession -Quiet) 'ARC 5 engine should load'
    Assert (-not (Test-KeystoneArcVaultUnlocked)) 'Vault starts locked'
    $locked = Get-KeystoneArcConnectionStatus
    Assert ($locked.arcLoaded -and -not $locked.arcUnlocked) 'Locked state not reported'
    Assert ($locked.arcVersion -eq '5') 'ARC version should be reported as 5'
    Assert (@($locked.itemNames).Count -eq 0) 'No names may be listed while locked'
    $lockedError = ''
    try { [void](Get-KeystoneToken -Provider GitHub) } catch { $lockedError = $_.Exception.Message }
    Assert ($lockedError -match '^ARC_LOCKED\|') "Locked vault must report ARC_LOCKED, got: $lockedError"

    $global:Arc5StubUnlockCalls = 0
    $state = Initialize-KeystoneArcAuthentication -Quiet
    Assert ($state.Unlocked) 'Initialize must unlock through Unlock-ArcVaultInteractive'
    Assert ($global:Arc5StubUnlockCalls -eq 1) 'ARC 5 unlock should be called exactly once'
    $again = Initialize-KeystoneArcAuthentication -Quiet
    Assert ($again.Unlocked -and $global:Arc5StubUnlockCalls -eq 1) 'An open vault must not be unlocked twice'

    $status = Get-KeystoneArcConnectionStatus
    Assert ($status.arcUnlocked) 'Unlocked state not reported'
    Assert ((@($status.itemNames) -join ',') -eq 'github,gitmil,twice') ('Item names wrong: ' + (@($status.itemNames) -join ','))
    $json = $status | ConvertTo-Json -Depth 6
    Assert ($json -notmatch 'fake-arc5') 'Connection status leaked a secret'

    Assert ((Get-KeystoneToken -Provider GitHub) -eq 'fake-arc5-github-token') 'GitHub token not read via Get-ArcSecret'
    Assert ((Get-KeystoneToken -Provider GitLab) -eq 'fake-arc5-gitlab-token') 'GitLab token not read via Get-ArcSecret'
    Assert ($null -eq (Get-KeystoneArcSecretByName -ServiceName 'twice')) 'Ambiguous items must not return a secret'
    Assert ((Get-KeystoneArcConnectionStatus).message -ne $null) 'Status must still render after an ambiguous lookup'

    $env:KEYSTONE_ARC_ITEM_GitHub = 'absent'
    $missing = ''
    try { [void](Get-KeystoneToken -Provider GitHub) } catch { $missing = $_.Exception.Message }
    Assert ($missing -match '^ARC_ITEM_MISSING\|') "Unmapped item must report ARC_ITEM_MISSING, got: $missing"
    $env:KEYSTONE_ARC_ITEM_GitHub = $null

    $env:GITHUB_TOKEN = 'env-wins'
    Assert ((Get-KeystoneToken -Provider GitHub) -eq 'env-wins') 'Approved environment credential should take precedence'
    Write-Host 'Keystone ARC 5 bridge contract passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module KeystoneArc -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
