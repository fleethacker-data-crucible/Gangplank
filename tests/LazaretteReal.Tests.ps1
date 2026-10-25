#Requires -Version 5.1
# Gangplank against the REAL Lazarette engine (lib\Lazarette.ps1 or lib\Arc.ps1), software (passphrase)
# profile, in a throwaway data folder. No CAC and no real vault: ARC_DATA points
# at a temp folder, so the runner's own %LOCALAPPDATA%\ARC (or \Lazarette) is never touched.
# Skips when no checkout is found: GANGPLANK_TEST_LAZARETTE_PATH (or the pre-rename
# KEYSTONE_TEST_ARC_PATH), else a sibling ..\lazarette, else ..\arc.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

$candidates = @($env:GANGPLANK_TEST_LAZARETTE_PATH, $env:KEYSTONE_TEST_ARC_PATH, (Join-Path (Split-Path $root -Parent) 'lazarette'), (Join-Path (Split-Path $root -Parent) 'arc'))
$laz = $null
foreach ($c in $candidates) {
    if (-not $c) { continue }
    foreach ($loader in @('Lazarette.ps1','Arc.ps1')) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $c 'lib') $loader) -PathType Leaf) { $laz = $c; break }
    }
    if ($laz) { break }
}
if (-not $laz) {
    Write-Host "SKIP: no Lazarette checkout found (set GANGPLANK_TEST_LAZARETTE_PATH)." -ForegroundColor Yellow
    return
}
$laz = [IO.Path]::GetFullPath($laz)
$data = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-real-test-' + [guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($n in @('ARC_PATH','ARC_ROOT','ARC_HOME','GANGPLANK_LAZARETTE_PATH','ARC_DATA','ARC_TEST_MODE','GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_LAZARETTE_ITEM_GitHub','GANGPLANK_LAZARETTE_ITEM_GitLab')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
try {
    [void](New-Item -ItemType Directory -Path $data -Force)
    $env:GANGPLANK_LAZARETTE_PATH = $laz
    $env:ARC_DATA = $data
    $env:ARC_TEST_MODE = '1'
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank -LogLevel ERROR
    Assert ((Get-GangplankLazaretteFlavor -LazaretteRoot $laz) -eq 'v5') 'Real Lazarette checkout should be detected as Lazarette (ARC 5)'
    Assert (Import-GangplankLazaretteSession -Quiet) ('Real Lazarette engine failed to load: ' + (Get-GangplankLazaretteConnectionStatus).message)

    # Test setup only: create a software vault the way Lazarette's own tests do. In
    # production the vault already exists and Unlock-ArcVaultInteractive prompts.
    $lazModule = Get-Module GangplankLazarette
    $pass = [Text.Encoding]::UTF8.GetBytes('gangplank test passphrase 42')
    & $lazModule {
        param($Dir,$Pass)
        $ctx = @{ Interactive = $false; Log = { param($l,$m) }; Passphrase = $Pass; Pbkdf2Iterations = 100000 }
        [void](New-ArcVault -Profile software -DataDir $Dir -Ctx $ctx)
        [void](Add-ArcRecord (New-ArcRecord -Service 'github' -User 'dev' -Secret 'real-lazarette-github-test-token'))
        [void](Add-ArcRecord (New-ArcRecord -Service 'gitmil' -User 'dev' -Secret 'real-lazarette-gitlab-test-token'))
        Lock-ArcVault
    } $data $pass

    $locked = Get-GangplankLazaretteConnectionStatus
    Assert ($locked.lazaretteLoaded -and -not $locked.lazaretteUnlocked -and $locked.lazaretteVersion -eq '5') 'Locked real Lazarette state not reported'
    $err = ''
    try { [void](Get-GangplankToken -Provider GitHub) } catch { $err = $_.Exception.Message }
    Assert ($err -match '^ARC_LOCKED\|') "Locked real vault must report ARC_LOCKED, got: $err"

    & $lazModule {
        param($Dir,$Pass)
        $o = Open-ArcVault -DataDir $Dir -Ctx @{ Interactive = $false; Log = { param($l,$m) }; Passphrase = $Pass }
        if (-not $o.Ok) { throw "Test unlock failed: $($o.Error)" }
    } $data $pass

    $status = Get-GangplankLazaretteConnectionStatus
    Assert ($status.lazaretteUnlocked) 'Unlocked real vault not reported'
    Assert ((@($status.itemNames) -join ',') -eq 'github,gitmil') ('Real item names wrong: ' + (@($status.itemNames) -join ','))
    Assert (($status | ConvertTo-Json -Depth 6) -notmatch 'real-arc5') 'Status leaked a real secret'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'real-lazarette-github-test-token') 'GitHub token not read from the real Lazarette vault'
    Assert ((Get-GangplankToken -Provider GitLab) -eq 'real-lazarette-gitlab-test-token') 'GitLab token not read from the real Lazarette vault'
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked) 'Initialize must not re-prompt an open vault'

    & $lazModule { Lock-ArcVault }
    Assert (-not (Test-GangplankLazaretteVaultUnlocked)) 'Lock was not observed'
    Write-Host 'Gangplank against the real Lazarette engine (software profile) passed.' -ForegroundColor Green
} finally {
    try { & (Get-Module GangplankLazarette) { Lock-ArcVault } } catch { }
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
}
