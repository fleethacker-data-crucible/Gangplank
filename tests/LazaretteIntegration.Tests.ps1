#Requires -Version 5.1
# Offline Lazarette bridge contract test. Uses a fake pm.ps1: no secrets, smart card, network, or real vault.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-contract-' + [guid]::NewGuid().ToString('N'))
$previous = [Environment]::GetEnvironmentVariable('GANGPLANK_LAZARETTE_PATH')
$previousToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
$mapping = Join-Path $root 'config\lazarette-items.local.json'
$oldMapping = $null
if (Test-Path -LiteralPath $mapping) { $oldMapping = Get-Content -LiteralPath $mapping -Raw }
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "FAILED: $message" } }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    $pm = @'
$script:PmState = @{ VaultUnlocked = $false }
# Mimic the real Lazarette dependency manifest; test missing library diagnosis.
$libOrder = @(
    '00-logging.ps1','00-core.ps1','01-storage.ps1','02-cac.ps1',
    '03-totp-core.ps1','03-totp-recovery.ps1','03-totp-setup.ps1',
    '04-wincred.ps1','05-update.ps1','06-ui.ps1','07-cli.ps1',
    '08-gui.ps1','09-integrity.ps1','10-stark.ps1'
)
function Ensure-VaultUnlocked {
    $global:FakeLazaretteUnlockCalls += 1
    $script:PmState.VaultUnlocked = $true
    return $true
}
function Get-PmStarkApiKey {
    param([string]$VaultName)
    if (-not $script:PmState.VaultUnlocked) { throw 'Vault locked' }
    switch ($VaultName) {
        'github' { return 'fake-github-test-token' }
        'github-alt' { return 'fake-alternate-test-token' }
        'gitlab' { return 'fake-gitlab-test-token' }
        'ai-api-key' { return 'fake-ai-test-token' }
        default { throw 'Missing test item' }
    }
}
function Get-PmVaultNameCatalog {
    if (-not $script:PmState.VaultUnlocked) { throw 'Vault locked' }
    $rows = New-Object System.Collections.ArrayList
    foreach ($name in @('github','github-alt','gitlab','ai-api-key')) {
        [void]$rows.Add([pscustomobject]@{ Service = $name; HasSecret = $true })
    }
    return ,$rows
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'pm.ps1'),$pm)
    # Lazarette's actual pm.ps1 requires a complete lib/ directory. Verify that
    # Gangplank reports incomplete installations instead of a vague status.
    $env:GANGPLANK_LAZARETTE_PATH = $temp
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank
    Assert (-not (Import-GangplankLazaretteSession -Quiet)) 'Incomplete Lazarette installation must be rejected'
    $incomplete = Get-GangplankLazaretteConnectionStatus
    Assert ($incomplete.code -eq 'ARC_MISSING_MODULES') 'Missing libs must be diagnosed'
    Assert ($incomplete.message -match 'Missing libraries') 'Missing libs message should be actionable'
    foreach ($name in (Get-GangplankLazaretteRequiredFiles)) {
        $full = Join-Path $temp $name
        $parent = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        [IO.File]::WriteAllText($full, '# fake library fixture')
    }
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    $global:FakeLazaretteUnlockCalls = 0
    Assert ((Find-GangplankLazaretteRoot) -eq $temp) 'GANGPLANK_LAZARETTE_PATH discovery'
    Assert (Import-GangplankLazaretteSession -Quiet) 'Lazarette dynamic module import'
    Assert (-not (Test-GangplankLazaretteVaultUnlocked)) 'Lazarette should begin locked'
    $secretWhenLocked = Get-GangplankLazaretteSecretByName -ServiceName github
    Assert (-not $secretWhenLocked) 'Secret must not be fetched while locked'
    Assert ($global:FakeLazaretteUnlockCalls -eq 0) 'HTTP-safe lookup may not trigger unlock'
    $wasRejected = $false
    try { $null = Get-GangplankToken -Provider GitHub } catch {
        $wasRejected = $_.Exception.Message -like 'ARC_LOCKED*'
    }
    Assert $wasRejected 'Locked vault must produce a useful diagnostic'
    Assert ($global:FakeLazaretteUnlockCalls -eq 0) 'Get-GangplankToken must not unlock implicitly'
    $initialized = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert $initialized.Unlocked 'Expected explicit startup unlock'
    Assert ($global:FakeLazaretteUnlockCalls -eq 1) 'Unlock only once at startup'
    Assert (Test-GangplankLazaretteVaultUnlocked) 'Unlocked state must be readable non-interactively'
    Assert (Import-GangplankLazaretteSession -Quiet) 'Subsequent import check should succeed'
    Assert ($global:FakeLazaretteUnlockCalls -eq 1) 'Lazarette import must not reset/authenticate again'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-github-test-token') 'GitHub token retrieval'
    Assert ((Get-GangplankToken -Provider GitLab) -eq 'fake-gitlab-test-token') 'GitLab token retrieval'
    $status = Get-GangplankLazaretteConnectionStatus
    Assert $status.lazaretteUnlocked 'Status must report unlocked'
    Assert ($status.itemNames -contains 'github') 'Catalog must unwrap Lazarette ArrayList'
    Assert (($status.integrations | Where-Object { $_.provider -eq 'GitHub' }).source -eq 'lazarette') 'GitHub mapped status'
    $serialized = $status | ConvertTo-Json -Depth 8
    Assert ($serialized -notmatch 'fake-github-test-token|fake-gitlab-test-token') 'Never return tokens to browser'
    [void](Set-GangplankLazaretteItemName -Provider GitHub -ServiceName github-alt)
    Assert ((Get-GangplankLazaretteItemName -Provider GitHub) -eq 'github-alt') 'Local Lazarette item mapping'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-alternate-test-token') 'Alternate service mapping'
    $saved = [IO.File]::ReadAllText($mapping)
    Assert ($saved -notmatch 'fake-.*-test-token') 'Local mapping must store names, never secrets'
    Write-Host 'Gangplank Lazarette import, smart card startup, token lookup, and mapping contract passed.' -ForegroundColor Green
} finally {
    if ($null -ne $oldMapping) {
        [IO.File]::WriteAllText($mapping,$oldMapping)
    } elseif (Test-Path -LiteralPath $mapping) {
        Remove-Item -LiteralPath $mapping -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previous) { Remove-Item Env:GANGPLANK_LAZARETTE_PATH -ErrorAction SilentlyContinue }
    else { $env:GANGPLANK_LAZARETTE_PATH = $previous }
    if ($null -eq $previousToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
    else { $env:GITHUB_TOKEN = $previousToken }
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
