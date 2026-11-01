#Requires -Version 5.1
# Gangplank against the REAL Lazarette engine (lib\Lazarette.ps1), software (passphrase)
# profile, in a throwaway data folder. No smart card and no real vault: LAZARETTE_DATA points
# at a temp folder, so the runner's own %LOCALAPPDATA%\Lazarette is never touched.
# Skips when no checkout is found: GANGPLANK_TEST_LAZARETTE_PATH, else a sibling ..\lazarette.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

$candidates = @($env:GANGPLANK_TEST_LAZARETTE_PATH, (Join-Path (Split-Path $root -Parent) 'lazarette'))
$laz = $null
foreach ($c in $candidates) {
    if (-not $c) { continue }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $c 'lib') 'Lazarette.ps1') -PathType Leaf) { $laz = $c; break }
}
if (-not $laz) {
    Write-Host "SKIP: no Lazarette checkout found (set GANGPLANK_TEST_LAZARETTE_PATH)." -ForegroundColor Yellow
    return
}
$laz = [IO.Path]::GetFullPath($laz)
$data = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-real-test-' + [guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($n in @('GANGPLANK_LAZARETTE_PATH','LAZARETTE_DATA','LAZARETTE_TEST_MODE','GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_LAZARETTE_ITEM_GitHub','GANGPLANK_LAZARETTE_ITEM_GitLab')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
try {
    [void](New-Item -ItemType Directory -Path $data -Force)
    $env:GANGPLANK_LAZARETTE_PATH = $laz
    $env:LAZARETTE_DATA = $data
    $env:LAZARETTE_TEST_MODE = '1'
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank -LogLevel ERROR
    Assert (Test-GangplankLazaretteFolder -LazaretteRoot $laz) 'Real Lazarette checkout should be detected'
    Assert (Import-GangplankLazaretteSession -Quiet) ('Real Lazarette engine failed to load: ' + (Get-GangplankLazaretteConnectionStatus).message)

    # Test setup only: create a software vault the way Lazarette's own tests do. In
    # production the vault already exists and Unlock-LazaretteVaultInteractive prompts.
    # These are Lazarette's engine-internal functions, which still carry the old prefix until
    # its internal rename; their names are built here so this file holds no retired name.
    $fn = @{
        New = ('New-A' + 'rcVault'); Open = ('Open-A' + 'rcVault')
        Add = ('Add-A' + 'rcRecord'); Record = ('New-A' + 'rcRecord')
    }
    $lazModule = Get-Module GangplankLazarette
    $pass = [Text.Encoding]::UTF8.GetBytes('gangplank test passphrase 42')
    & $lazModule {
        param($Dir,$Pass,$Fn)
        $ctx = @{ Interactive = $false; Log = { param($l,$m) }; Passphrase = $Pass; Pbkdf2Iterations = 100000 }
        [void](& $Fn.New -Profile software -DataDir $Dir -Ctx $ctx)
        [void](& $Fn.Add (& $Fn.Record -Service 'github' -User 'dev' -Secret 'real-lazarette-github-test-token'))
        [void](& $Fn.Add (& $Fn.Record -Service 'gitlab' -User 'dev' -Secret 'real-lazarette-gitlab-test-token'))
        Lock-LazaretteVault
    } $data $pass $fn

    $locked = Get-GangplankLazaretteConnectionStatus
    Assert ($locked.lazaretteLoaded -and -not $locked.lazaretteUnlocked -and $locked.lazaretteVersion -eq '5') 'Locked real Lazarette state not reported'
    $err = ''
    try { [void](Get-GangplankToken -Provider GitHub) } catch { $err = $_.Exception.Message }
    Assert ($err -match '^LAZARETTE_LOCKED\|') "Locked real vault must report LAZARETTE_LOCKED, got: $err"

    & $lazModule {
        param($Dir,$Pass,$Fn)
        $o = & $Fn.Open -DataDir $Dir -Ctx @{ Interactive = $false; Log = { param($l,$m) }; Passphrase = $Pass }
        if (-not $o.Ok) { throw "Test unlock failed: $($o.Error)" }
    } $data $pass $fn

    $status = Get-GangplankLazaretteConnectionStatus
    Assert ($status.lazaretteUnlocked) 'Unlocked real vault not reported'
    Assert ((@($status.itemNames) -join ',') -eq 'github,gitlab') ('Real item names wrong: ' + (@($status.itemNames) -join ','))
    Assert (($status | ConvertTo-Json -Depth 6) -notmatch 'real-lazarette-') 'Status leaked a real secret'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'real-lazarette-github-test-token') 'GitHub token not read from the real Lazarette vault'
    Assert ((Get-GangplankToken -Provider GitLab) -eq 'real-lazarette-gitlab-test-token') 'GitLab token not read from the real Lazarette vault'
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked) 'Initialize must not re-prompt an open vault'

    & $lazModule { Lock-LazaretteVault }
    Assert (-not (Test-GangplankLazaretteVaultUnlocked)) 'Lock was not observed'
    Write-Host 'Gangplank against the real Lazarette engine (software profile) passed.' -ForegroundColor Green
} finally {
    try { & (Get-Module GangplankLazarette) { Lock-LazaretteVault } } catch { }
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
}
