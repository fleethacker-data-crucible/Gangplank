#Requires -Version 5.1
# Offline Lazarette bridge test. Uses a fake lib\Lazarette.ps1: no secrets, smart card, network, or real vault.
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
    [void](New-Item -ItemType Directory -Path (Join-Path $temp 'lib') -Force)
    $loader = Join-Path (Join-Path $temp 'lib') 'Lazarette.ps1'
    $env:GANGPLANK_LAZARETTE_PATH = $temp
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank

    # A configured folder without lib\Lazarette.ps1 is reported, not guessed at.
    Assert (-not (Find-GangplankLazaretteRoot)) 'A folder without lib\Lazarette.ps1 must not be found'
    Assert (-not (Import-GangplankLazaretteSession -Quiet)) 'Import must fail without lib\Lazarette.ps1'
    Assert ((Get-GangplankLazaretteConnectionStatus).code -eq 'LAZARETTE_NOT_FOUND') 'Missing loader must be diagnosed as LAZARETTE_NOT_FOUND'

    # A loader that throws is reported as an initialization failure.
    [IO.File]::WriteAllText($loader,"throw 'boom'")
    Assert (-not (Import-GangplankLazaretteSession -Quiet)) 'A loader that throws must be rejected'
    Assert ((Get-GangplankLazaretteConnectionStatus).code -eq 'LAZARETTE_LIBRARY_INITIALIZATION_FAILED') 'Failed load must be diagnosed'
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue

    [IO.File]::WriteAllText($loader,@'
$script:StubUnlocked = $false
$script:Names = @('github','github-alt','gitlab')
function Test-LazaretteVaultUnlocked { return $script:StubUnlocked }
function Unlock-LazaretteVaultInteractive { $global:FakeLazaretteUnlockCalls += 1; $script:StubUnlocked = $true; return $true }
function Get-LazaretteItemNames {
    if (-not $script:StubUnlocked) { throw 'Vault locked' }
    return @($script:Names | ForEach-Object { [pscustomobject]@{ Service = $_; User = 'me'; Type = 'api'; Tags = '' } })
}
function Get-LazaretteSecret {
    param([Parameter(Mandatory)][string]$Service, [string]$User = '', [string]$Field = '')
    if (-not $script:StubUnlocked) { throw 'Vault locked' }
    switch ($Service) {
        'github' { return 'fake-github-test-token' }
        'github-alt' { return 'fake-alternate-test-token' }
        'gitlab' { return 'fake-gitlab-test-token' }
        default { throw 'Missing test item' }
    }
}
'@)
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
        $wasRejected = $_.Exception.Message -like 'LAZARETTE_LOCKED*'
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
    Assert ($status.itemNames -contains 'github') 'Catalog must list the item names'
    Assert (($status.integrations | Where-Object { $_.provider -eq 'GitHub' }).source -eq 'lazarette') 'GitHub mapped status'
    $serialized = $status | ConvertTo-Json -Depth 8
    Assert ($serialized -notmatch 'fake-github-test-token|fake-gitlab-test-token') 'Never return tokens to browser'
    [void](Set-GangplankLazaretteItemName -Provider GitHub -ServiceName github-alt)
    Assert ((Get-GangplankLazaretteItemName -Provider GitHub) -eq 'github-alt') 'Local Lazarette item mapping'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-alternate-test-token') 'Alternate service mapping'
    $saved = [IO.File]::ReadAllText($mapping)
    Assert ($saved -notmatch 'fake-.*-test-token') 'Local mapping must store names, never secrets'
    Write-Host 'Gangplank Lazarette import, startup unlock, token lookup, and mapping contract passed.' -ForegroundColor Green
} finally {
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
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
