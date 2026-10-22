#Requires -Version 5.1
# Offline ARC bridge contract test. Uses a fake pm.ps1: no secrets, CAC, network, or real vault.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-arc-contract-' + [guid]::NewGuid().ToString('N'))
$previous = [Environment]::GetEnvironmentVariable('ARC_PATH')
$previousToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
$mapping = Join-Path $root 'config\arc-items.local.json'
$oldMapping = $null
if (Test-Path -LiteralPath $mapping) { $oldMapping = Get-Content -LiteralPath $mapping -Raw }
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "FAILED: $message" } }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    $pm = @'
$script:PmState = @{ VaultUnlocked = $false }
function Ensure-VaultUnlocked {
    $global:FakeArcUnlockCalls += 1
    $script:PmState.VaultUnlocked = $true
    return $true
}
function Get-PmStarkApiKey {
    param([string]$VaultName)
    if (-not $script:PmState.VaultUnlocked) { throw 'Vault locked' }
    switch ($VaultName) {
        'github' { return 'fake-github-test-token' }
        'github-alt' { return 'fake-alternate-test-token' }
        'gitmil' { return 'fake-gitlab-test-token' }
        'genapi' { return 'fake-genai-test-token' }
        default { throw 'Missing test item' }
    }
}
function Get-PmVaultNameCatalog {
    if (-not $script:PmState.VaultUnlocked) { throw 'Vault locked' }
    $rows = New-Object System.Collections.ArrayList
    foreach ($name in @('github','github-alt','gitmil','genapi')) {
        [void]$rows.Add([pscustomobject]@{ Service = $name; HasSecret = $true })
    }
    return ,$rows
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'pm.ps1'),$pm)
    $env:ARC_PATH = $temp
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    $global:FakeArcUnlockCalls = 0
    Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
    Initialize-Keystone
    Assert ((Find-KeystoneArcRoot) -eq $temp) 'ARC_PATH discovery'
    Assert (Import-KeystoneArcSession -Quiet) 'ARC dynamic module import'
    Assert (-not (Test-KeystoneArcVaultUnlocked)) 'ARC should begin locked'
    $secretWhenLocked = Get-KeystoneArcSecretByName -ServiceName github
    Assert (-not $secretWhenLocked) 'Secret must not be fetched while locked'
    Assert ($global:FakeArcUnlockCalls -eq 0) 'HTTP-safe lookup may not trigger unlock'
    $wasRejected = $false
    try { $null = Get-KeystoneToken -Provider GitHub } catch {
        $wasRejected = $_.Exception.Message -like 'ARC_LOCKED*'
    }
    Assert $wasRejected 'Locked vault must produce a useful diagnostic'
    Assert ($global:FakeArcUnlockCalls -eq 0) 'Get-KeystoneToken must not unlock implicitly'
    $initialized = Initialize-KeystoneArcAuthentication -Quiet
    Assert $initialized.Unlocked 'Expected explicit startup unlock'
    Assert ($global:FakeArcUnlockCalls -eq 1) 'Unlock only once at startup'
    Assert (Test-KeystoneArcVaultUnlocked) 'Unlocked state must be readable non-interactively'
    Assert (Import-KeystoneArcSession -Quiet) 'Subsequent import check should succeed'
    Assert ($global:FakeArcUnlockCalls -eq 1) 'ARC import must not reset/authenticate again'
    Assert ((Get-KeystoneToken -Provider GitHub) -eq 'fake-github-test-token') 'GitHub token retrieval'
    Assert ((Get-KeystoneToken -Provider GitLab) -eq 'fake-gitlab-test-token') 'GitLab token retrieval'
    $status = Get-KeystoneArcConnectionStatus
    Assert $status.arcUnlocked 'Status must report unlocked'
    Assert ($status.itemNames -contains 'github') 'Catalog must unwrap ARC ArrayList'
    Assert (($status.integrations | Where-Object { $_.provider -eq 'GitHub' }).source -eq 'arc') 'GitHub mapped status'
    $serialized = $status | ConvertTo-Json -Depth 8
    Assert ($serialized -notmatch 'fake-github-test-token|fake-gitlab-test-token') 'Never return tokens to browser'
    [void](Set-KeystoneArcItemName -Provider GitHub -ServiceName github-alt)
    Assert ((Get-KeystoneArcItemName -Provider GitHub) -eq 'github-alt') 'Local ARC item mapping'
    Assert ((Get-KeystoneToken -Provider GitHub) -eq 'fake-alternate-test-token') 'Alternate service mapping'
    $saved = [IO.File]::ReadAllText($mapping)
    Assert ($saved -notmatch 'fake-.*-test-token') 'Local mapping must store names, never secrets'
    Write-Host 'Keystone ARC import, CAC startup, token lookup, and mapping contract passed.' -ForegroundColor Green
} finally {
    if ($null -ne $oldMapping) {
        [IO.File]::WriteAllText($mapping,$oldMapping)
    } elseif (Test-Path -LiteralPath $mapping) {
        Remove-Item -LiteralPath $mapping -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previous) { Remove-Item Env:ARC_PATH -ErrorAction SilentlyContinue }
    else { $env:ARC_PATH = $previous }
    if ($null -eq $previousToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
    else { $env:GITHUB_TOKEN = $previousToken }
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
