#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Core/Sentinel.ps1')
function Assert($value,[string]$message) { if (-not $value) { throw "FAIL: $message" } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-sentinel-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root)
try {
    $clean = Join-Path $root 'clean.ps1'
    [IO.File]::WriteAllText($clean,'Write-Output "hello"')
    Assert (@(Get-GangplankSentinelFindings -Path $clean).Count -eq 0) 'Clean code incorrectly flagged'
    $secret = Join-Path $root 'secret.txt'
    [IO.File]::WriteAllText($secret,'ghp_' + ('A' * 36))
    Assert ('GITHUB_TOKEN' -in @(Get-GangplankSentinelFindings -Path $secret | ForEach-Object Code)) 'Token detection'
    $pii = Join-Path $root 'test.csv'
    [IO.File]::WriteAllText($pii,'id,ssn' + [Environment]::NewLine + '1,123-45-6789')
    Assert ('SSN_CANDIDATE' -in @(Get-GangplankSentinelFindings -Path $pii | ForEach-Object Code)) 'PII detection'
    $marking = Join-Path $root 'control.md'
    [IO.File]::WriteAllText($marking,'CONTROLLED UNCLASSIFIED INFORMATION')
    Assert ('DATA_MARKING' -in @(Get-GangplankSentinelFindings -Path $marking | ForEach-Object Code)) 'Data-handling marking'
    $binary = Join-Path $root 'image.png'
    [IO.File]::WriteAllBytes($binary,[byte[]](1,2,3))
    Assert ('TYPE_MISMATCH' -in @(Get-GangplankSentinelFindings -Path $binary | ForEach-Object Code)) 'A .png whose bytes are not a PNG is blocked'
    $unknown = Join-Path $root 'data.bin'
    [IO.File]::WriteAllBytes($unknown,[byte[]](1,2,3))
    Assert ('FORMAT_UNVERIFIED' -in @(Get-GangplankSentinelFindings -Path $unknown | ForEach-Object Code)) 'An unknown format is blocked'
    $png = Join-Path $root 'logo.png'
    [IO.File]::WriteAllBytes($png,[byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0,0,0,0))
    $pngFinding = @(Get-GangplankSentinelFindings -Path $png)
    Assert ($pngFinding.Count -eq 1 -and $pngFinding[0].Code -eq 'BINARY_NOT_INSPECTED' -and $pngFinding[0].Severity -eq 'Review') 'A verified PNG needs a review, it is not blocked outright'
    $pdf = Join-Path $root 'paper.pdf'
    [IO.File]::WriteAllBytes($pdf,[Text.Encoding]::ASCII.GetBytes('%PDF-1.7 fictional'))
    Assert ('BINARY_NOT_INSPECTED' -in @(Get-GangplankSentinelFindings -Path $pdf | ForEach-Object Code)) 'A verified PDF needs a review'
    $github = [pscustomobject]@{}
    $github | Add-Member ScriptMethod InvokeApi { param($method,$path) return [pscustomobject]@{ private=$false; visibility='public' } }
    $session = [pscustomobject]@{ Provider='GitHub'; ProviderObj=$github; ProjectPath='demo/repo'; LocalPath=$root }
    $ok = Test-GangplankSentinelPublication -Session $session -Paths @('clean.ps1')
    Assert ($ok.Allowed -and $ok.RequiresPublicConfirmation) 'Public GitHub visibility check'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('secret.txt')).Allowed) 'Secret was allowed'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('missing.ps1')).Allowed) 'Missing file was allowed'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('../escape.ps1')).Allowed) 'Traversal was allowed'
    $gitlab = [pscustomobject]@{}
    $gitlab | Add-Member ScriptMethod EncodePath { param($path) return 'demo%2Frepo' }
    $gitlab | Add-Member ScriptMethod InvokeApi { param($method,$path) return [pscustomobject]@{ visibility='private' } }
    $session.Provider = 'GitLab'
    $session.ProviderObj = $gitlab
    $safe = Test-GangplankSentinelPublication -Session $session -Paths @('clean.ps1')
    Assert ($safe.Allowed -and $safe.Destination.Verified -and -not $safe.RequiresPublicConfirmation) 'Private GitLab incorrectly blocked'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('control.md')).Allowed) 'Data-handling marking review was bypassed'
    # A review finding can be acknowledged per file, with a reason; a block finding never can.
    $ack = Test-GangplankSentinelPublication -Session $session -Paths @('control.md') -Acknowledgements @{ 'control.md' = 'Authorized handling confirmed with the owner' }
    Assert ($ack.Allowed -and @($ack.Acknowledged).Count -eq 1 -and $ack.Acknowledged[0].Code -eq 'DATA_MARKING') 'A reasoned acknowledgement allows a review finding'
    $threw = $false
    try { [void](Test-GangplankSentinelPublication -Session $session -Paths @('control.md') -Acknowledgements @{ 'control.md' = 'ok' }) } catch { $threw = $true }
    Assert $threw 'A reason that is too short is refused'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('secret.txt') -Acknowledgements @{ 'secret.txt' = 'I know what I am doing here' }).Allowed) 'A block finding can never be acknowledged'
    Assert (@((Test-GangplankSentinelPublication -Session $session -Paths @('clean.ps1') -Acknowledgements @{ 'clean.ps1' = 'not needed at all' }).Acknowledged).Count -eq 0) 'Nothing to acknowledge on a clean file'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('logo.png')).Allowed) 'A verified image is not published without an acknowledgement'
    Assert ((Test-GangplankSentinelPublication -Session $session -Paths @('logo.png') -Acknowledgements @{ 'logo.png' = 'Team logo, checked by eye' }).Allowed) 'A verified image can be acknowledged'
    Assert (-not (Test-GangplankSentinelPublication -Session $session -Paths @('image.png') -Acknowledgements @{ 'image.png' = 'It is surely a picture' }).Allowed) 'A mislabelled file is blocked even with a reason'
    # One rule list: the secret file-name rule and the block-level content rules exist once, in Core, and both
    # Smart Save's change list and Sentinel call them.
    $core = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../Core') -Filter *.ps1 | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join [Environment]::NewLine
    foreach ($literal in @('^id_(rsa|ed25519)', '-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----', '(?:AKIA|ASIA)[0-9A-Z]{16}')) {
        Assert (([regex]::Matches($core,[regex]::Escape($literal)).Count) -eq 1) ('Rule defined more than once: ' + $literal)
    }
    foreach ($n in @('.env','.ENV.local','id_rsa','Credentials.json','secrets.json','server.pem','deploy.key','token')) { Assert (Test-GangplankSecretName -Name $n) ("Secret name not recognised: $n") }
    foreach ($n in @('notes.txt','readme.md','environment.md','keyboard.js')) { Assert (-not (Test-GangplankSecretName -Name $n)) ("Plain name flagged: $n") }
    Assert (Test-GangplankSecretText -Text ('ghp_' + ('B' * 30))) 'Token text recognised'
    Assert (-not (Test-GangplankSecretText -Text 'just some prose')) 'Prose is not a secret'
    Write-Host 'Sentinel fixture tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
