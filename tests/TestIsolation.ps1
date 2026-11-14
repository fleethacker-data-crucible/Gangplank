#Requires -Version 5.1
# Dot-source right after importing Gangplank in a test. Points Gangplank's credential
# store at a throwaway folder, so a test never reads or writes the real
# %LOCALAPPDATA%\Gangplank\credentials.json of whoever runs it (the CI runner runs
# as a real user account).
$script:GangplankTestStoreDir = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-test-store-' + [guid]::NewGuid().ToString('N'))
& (Get-Module Gangplank) {
    param($Dir)
    $script:GangplankCredentialStorePath = Join-Path $Dir 'credentials.json'
    # Never read a real Fairlead local token, and never start a real Fairlead, from a test process.
    # Suites that exercise those paths set their own file and their own check.
    $script:GangplankFairleadLocalTokenPath = Join-Path $Dir 'no-fairlead-local-token'
    $script:GangplankFleetPortModulePath = Join-Path $Dir 'no-fleetport.psm1'
    $script:GangplankFairleadReadyOverride = { }
} $script:GangplankTestStoreDir
