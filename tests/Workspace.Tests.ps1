#Requires -Version 5.1
# Offline validation; no Git, GitHub, GitLab, AI or Pester required.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Keystone.psm1') -Force
function Assert($value,[string]$message) { if (-not $value) { throw "FAIL: $message" } }
$sourceFiles = @(Get-ChildItem -LiteralPath $root -Include '*.ps1','*.psm1' -File -Recurse)
foreach ($file in $sourceFiles) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert (@($errors).Count -eq 0) ("Parse failed: " + $file.FullName + ' ' + ($errors -join '; '))
}
Write-Host ("Parsed {0} PowerShell source files" -f $sourceFiles.Count)
Assert-KeystoneTrustedRepositoryUrl -Url 'https://github.com/ashable2/keystone'
Assert-KeystoneTrustedRepositoryUrl -Url 'https://web.git.mil/group/project'
foreach ($url in @('http://github.com/a/b','https://github.com.evil.invalid/a/b','https://localhost/a/b','https://user:secret@github.com/a/b')) {
    $rejected = $false
    try { Assert-KeystoneTrustedRepositoryUrl -Url $url } catch { $rejected = $true }
    Assert $rejected ("Untrusted URL accepted: " + $url)
}
Assert (Test-KeystoneSensitivePath -Path '.env') 'Protect .env'
Assert (Test-KeystoneSensitivePath -Path 'config/credentials.json') 'Protect credentials'
Assert (-not (Test-KeystoneSensitivePath -Path 'src/Hello.ps1')) 'Allow source files'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    $keep = Join-Path $temp 'keep.txt'
    [IO.File]::WriteAllText($keep,'DO NOT DELETE')
    $fake = [pscustomobject]@{ DefaultBranch = 'main' }
    $refused = $false
    try { Invoke-KeystonePull -Session $fake -Branch main -LocalPath $temp | Out-Null } catch { $refused = $true }
    Assert $refused 'Download must refuse nonempty folder'
    Assert (([IO.File]::ReadAllText($keep)) -eq 'DO NOT DELETE') 'File must be preserved'
    $provider = New-Object psobject -Property @{ CurrentHead = 'abc123' }
    $provider | Add-Member -MemberType ScriptMethod -Name GetRefSha -Value { param($project,$branch) return $this.CurrentHead }
    $session = [pscustomobject]@{
        Provider = 'GitHub'; ProviderObj = $provider; ProjectPath = 'team/demo'
        DefaultBranch = 'main'; LastBranch = 'main'; LocalPath = $temp
        BaselineSha = 'abc123'; BaselineMap = @{ 'keep.txt' = 'old-hash'; 'gone.txt' = 'previous-hash' }
    }
    $preview = Get-KeystoneWorkspacePreview -Session $session
    Assert (-not $preview.RemoteChanged) 'Unexpected stale result'
    Assert (@($preview.Changes | Where-Object { $_.Kind -eq 'Modified' }).Count -eq 1) 'Modified file was missed'
    Assert (@($preview.Changes | Where-Object { $_.Kind -eq 'Deleted' -and $_.Selected }).Count -eq 0) 'Deletion selected automatically'
    $provider.CurrentHead = 'other'
    Assert (Get-KeystoneWorkspacePreview -Session $session).RemoteChanged 'Remote update was not found'
    $blocked = $false
    try { Invoke-KeystoneWorkspaceSave -Session $session -SelectedPaths @('keep.txt') | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Stale changes must not be saved'
} finally {
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
$one = New-KeystoneSmartMessage -Added @('src/New.ps1')
Assert ($one.HasChanges -and $one.Title -match '^feat') 'Smart title invalid'
Assert (-not (New-KeystoneSmartMessage).HasChanges) 'Empty save invalid'
Write-Host 'All offline Keystone checks passed.' -ForegroundColor Green
