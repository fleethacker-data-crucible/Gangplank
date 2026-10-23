#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Core/Sentinel.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sentinel-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
 $clean=Join-Path $root 'clean.ps1';[IO.File]::WriteAllText($clean,'Write-Output "hello"')
 if(@(Get-KeystoneSentinelFindings $clean).Count -ne 0){throw 'Clean fixture flagged'}
 $secret=Join-Path $root 'secret.txt';[IO.File]::WriteAllText($secret,'ghp_'+('A'*36))
 if('GITHUB_TOKEN' -notin @(Get-KeystoneSentinelFindings $secret|ForEach-Object Code)){throw 'Token detection failed'}
 $pii=Join-Path $root 'test.csv';[IO.File]::WriteAllText($pii,'id,ssn'+[Environment]::NewLine+'1,123-45-6789')
 if('SSN_CANDIDATE' -notin @(Get-KeystoneSentinelFindings $pii|ForEach-Object Code)){throw 'PII detection failed'}
 $binary=Join-Path $root 'image.png';[IO.File]::WriteAllBytes($binary,[byte[]](1,2,3))
 if('FORMAT_UNVERIFIED' -notin @(Get-KeystoneSentinelFindings $binary|ForEach-Object Code)){throw 'Unsupported file not blocked'}
 $provider=[pscustomobject]@{};$provider|Add-Member ScriptMethod InvokeApi {param($method,$path) return [pscustomobject]@{private=$false;visibility='public'}}
 $session=[pscustomobject]@{Provider='GitHub';ProviderObj=$provider;ProjectPath='sample/project';LocalPath=$root}
 $result=Test-KeystoneSentinelPublication -Session $session -Paths @('clean.ps1')
 if(-not $result.Allowed -or -not $result.RequiresPublicConfirmation){throw 'Public destination check failed'}
 $result=Test-KeystoneSentinelPublication -Session $session -Paths @('secret.txt')
 if($result.Allowed){throw 'Secret was allowed'}
 Write-Output 'Sentinel tests passed.'
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
