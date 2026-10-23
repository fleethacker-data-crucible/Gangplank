#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Core/Sentinel.ps1')
function Assert($value,[string]$message) { if (-not $value) { throw "FAIL: $message" } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('keystone-sentinel-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root)
try {
    $clean = Join-Path $root 'clean.ps1'
    [IO.File]::WriteAllText($clean,'Write-Output "hello"')
    Assert (@(Get-KeystoneSentinelFindings -Path $clean).Count -eq 0) 'Clean code incorrectly flagged'
    $secret = Join-Path $root 'secret.txt'
    [IO.File]::WriteAllText($secret,'ghp_' + ('A' * 36))
    Assert ('GITHUB_TOKEN' -in @(Get-KeystoneSentinelFindings -Path $secret | ForEach-Object Code)) 'Token detection'
    $pii = Join-Path $root 'test.csv'
    [IO.File]::WriteAllText($pii,'id,ssn' + [Environment]::NewLine + '1,123-45-6789')
    Assert ('SSN_CANDIDATE' -in @(Get-KeystoneSentinelFindings -Path $pii | ForEach-Object Code)) 'PII detection'
    $cui = Join-Path $root 'control.md'
    [IO.File]::WriteAllText($cui,'CONTROLLED UNCLASSIFIED INFORMATION')
    Assert ('CUI_MARKING' -in @(Get-KeystoneSentinelFindings -Path $cui | ForEach-Object Code)) 'CUI marking'
    $binary = Join-Path $root 'image.png'
    [IO.File]::WriteAllBytes($binary,[byte[]](1,2,3))
    Assert ('FORMAT_UNVERIFIED' -in @(Get-KeystoneSentinelFindings -Path $binary | ForEach-Object Code)) 'Unsupported file blocked'
    $github = [pscustomobject]@{}
    $github | Add-Member ScriptMethod InvokeApi { param($method,$path) return [pscustomobject]@{ private=$false; visibility='public' } }
    $session = [pscustomobject]@{ Provider='GitHub'; ProviderObj=$github; ProjectPath='demo/repo'; LocalPath=$root }
    $ok = Test-KeystoneSentinelPublication -Session $session -Paths @('clean.ps1')
    Assert ($ok.Allowed -and $ok.RequiresPublicConfirmation) 'Public GitHub visibility check'
    Assert (-not (Test-KeystoneSentinelPublication -Session $session -Paths @('secret.txt')).Allowed) 'Secret was allowed'
    Assert (-not (Test-KeystoneSentinelPublication -Session $session -Paths @('missing.ps1')).Allowed) 'Missing file was allowed'
    Assert (-not (Test-KeystoneSentinelPublication -Session $session -Paths @('../escape.ps1')).Allowed) 'Traversal was allowed'
    $gitlab = [pscustomobject]@{}
    $gitlab | Add-Member ScriptMethod EncodePath { param($path) return 'demo%2Frepo' }
    $gitlab | Add-Member ScriptMethod InvokeApi { param($method,$path) return [pscustomobject]@{ visibility='private' } }
    $session.Provider = 'GitLab'
    $session.ProviderObj = $gitlab
    $safe = Test-KeystoneSentinelPublication -Session $session -Paths @('clean.ps1')
    Assert ($safe.Allowed -and $safe.Destination.Verified -and -not $safe.RequiresPublicConfirmation) 'Private GitLab incorrectly blocked'
    Assert (-not (Test-KeystoneSentinelPublication -Session $session -Paths @('control.md')).Allowed) 'CUI review was bypassed'
    Write-Host 'Sentinel fixture tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
