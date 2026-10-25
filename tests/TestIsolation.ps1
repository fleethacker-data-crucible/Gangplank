#Requires -Version 5.1
# Dot-source right after importing Keystone in a test. Points Keystone's credential
# store at a throwaway folder, so a test never reads or writes the real
# %LOCALAPPDATA%\Keystone\credentials.json of whoever runs it (the CI runner runs
# as a real user account).
$script:KeystoneTestStoreDir = Join-Path ([IO.Path]::GetTempPath()) ('keystone-test-store-' + [guid]::NewGuid().ToString('N'))
& (Get-Module Keystone) { param($Dir) $script:KeystoneCredentialStorePath = Join-Path $Dir 'credentials.json' } $script:KeystoneTestStoreDir
