#Requires -Version 5.1
# Keystone against the REAL ARC 5 engine (lib\Arc.ps1), software (passphrase)
# profile, in a throwaway data folder. No CAC and no real vault: ARC_DATA points
# at a temp folder, so the runner's own %LOCALAPPDATA%\ARC is never touched.
# Skips when no ARC 5 checkout is found (KEYSTONE_TEST_ARC_PATH or ..\arc).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

$arc = $env:KEYSTONE_TEST_ARC_PATH
if (-not $arc) { $arc = Join-Path (Split-Path $root -Parent) 'arc' }
if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $arc 'lib') 'Arc.ps1') -PathType Leaf)) {
    Write-Host "SKIP: no ARC 5 checkout at '$arc' (set KEYSTONE_TEST_ARC_PATH)." -ForegroundColor Yellow
    return
}
$arc = [IO.Path]::GetFullPath($arc)
$data = Join-Path ([IO.Path]::GetTempPath()) ('keystone-arc5-real-test-' + [guid]::NewGuid().ToString('N'))
$saved = @{}
foreach ($n in @('ARC_PATH','ARC_ROOT','ARC_HOME','KEYSTONE_ARC_PATH','ARC_DATA','ARC_TEST_MODE','GITHUB_TOKEN','GITLAB_TOKEN','KEYSTONE_ARC_ITEM_GitHub','KEYSTONE_ARC_ITEM_GitLab')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}
try {
    [void](New-Item -ItemType Directory -Path $data -Force)
    $env:KEYSTONE_ARC_PATH = $arc
    $env:ARC_DATA = $data
    $env:ARC_TEST_MODE = '1'
    Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Keystone -LogLevel ERROR
    Assert ((Get-KeystoneArcFlavor -ArcRoot $arc) -eq 'v5') 'Real ARC checkout should be detected as ARC 5'
    Assert (Import-KeystoneArcSession -Quiet) ('Real ARC 5 engine failed to load: ' + (Get-KeystoneArcConnectionStatus).message)

    # Test setup only: create a software vault the way ARC's own tests do. In
    # production the vault already exists and Unlock-ArcVaultInteractive prompts.
    $arcModule = Get-Module KeystoneArc
    $pass = [Text.Encoding]::UTF8.GetBytes('keystone test passphrase 42')
    & $arcModule {
        param($Dir,$Pass)
        $ctx = @{ Interactive = $false; Log = { param($l,$m) }; Passphrase = $Pass; Pbkdf2Iterations = 100000 }
        [void](New-ArcVault -Profile software -DataDir $Dir -Ctx $ctx)
        [void](Add-ArcRecord (New-ArcRecord -Service 'github' -User 'dev' -Secret 'real-arc5-github-test-token'))
        [void](Add-ArcRecord (New-ArcRecord -Service 'gitmil' -User 'dev' -Secret 'real-arc5-gitlab-test-token'))
        Lock-ArcVault
    } $data $pass

    $locked = Get-KeystoneArcConnectionStatus
    Assert ($locked.arcLoaded -and -not $locked.arcUnlocked -and $locked.arcVersion -eq '5') 'Locked real ARC 5 state not reported'
    $err = ''
    try { [void](Get-KeystoneToken -Provider GitHub) } catch { $err = $_.Exception.Message }
    Assert ($err -match '^ARC_LOCKED\|') "Locked real vault must report ARC_LOCKED, got: $err"

    & $arcModule {
        param($Dir,$Pass)
        $o = Open-ArcVault -DataDir $Dir -Ctx @{ Interactive = $false; Log = { param($l,$m) }; Passphrase = $Pass }
        if (-not $o.Ok) { throw "Test unlock failed: $($o.Error)" }
    } $data $pass

    $status = Get-KeystoneArcConnectionStatus
    Assert ($status.arcUnlocked) 'Unlocked real vault not reported'
    Assert ((@($status.itemNames) -join ',') -eq 'github,gitmil') ('Real item names wrong: ' + (@($status.itemNames) -join ','))
    Assert (($status | ConvertTo-Json -Depth 6) -notmatch 'real-arc5') 'Status leaked a real secret'
    Assert ((Get-KeystoneToken -Provider GitHub) -eq 'real-arc5-github-test-token') 'GitHub token not read from the real ARC 5 vault'
    Assert ((Get-KeystoneToken -Provider GitLab) -eq 'real-arc5-gitlab-test-token') 'GitLab token not read from the real ARC 5 vault'
    $state = Initialize-KeystoneArcAuthentication -Quiet
    Assert ($state.Unlocked) 'Initialize must not re-prompt an open vault'

    & $arcModule { Lock-ArcVault }
    Assert (-not (Test-KeystoneArcVaultUnlocked)) 'Lock was not observed'
    Write-Host 'Keystone against the real ARC 5 engine (software profile) passed.' -ForegroundColor Green
} finally {
    try { & (Get-Module KeystoneArc) { Lock-ArcVault } } catch { }
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module KeystoneArc -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
}
