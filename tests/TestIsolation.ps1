#Requires -Version 5.1
# Dot-source right after importing Gangplank in a test. Points Gangplank's credential
# store at a throwaway folder, so a test never reads or writes the real
# %LOCALAPPDATA%\Gangplank\credentials.json of whoever runs it (the CI runner runs
# as a real user account).
$script:GangplankTestStoreDir = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-test-store-' + [guid]::NewGuid().ToString('N'))
& (Get-Module Gangplank) { param($Dir) $script:GangplankCredentialStorePath = Join-Path $Dir 'credentials.json' } $script:GangplankTestStoreDir
