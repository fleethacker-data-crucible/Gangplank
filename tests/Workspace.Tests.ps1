#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert($value,[string]$message) { if (-not $value) { throw "FAIL: $message" } }
$sourceFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '[\\/]Providers[\\/]' })
foreach ($file in $sourceFiles) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert (@($errors).Count -eq 0) ("Parse failed: " + $file.FullName + ' ' + ($errors -join '; '))
}
Write-Host ("Parsed {0} PowerShell scripts" -f $sourceFiles.Count)
Assert-GangplankTrustedRepositoryUrl -Url 'https://github.com/fleethacker-data-crucible/Gangplank'
# No GitLab host is trusted by default: only the host the user configures.
$savedGitLabHost = $env:GANGPLANK_GITLAB_HOST
$savedAllowed = $env:GANGPLANK_GITLAB_ALLOWED_HOSTS
try {
    $env:GANGPLANK_GITLAB_HOST = $null
    $env:GANGPLANK_GITLAB_ALLOWED_HOSTS = $null
    Assert ((& (Get-Module Gangplank) { Get-GangplankGitLabHost }) -eq '') 'No GitLab host should be configured by default'
    Assert (@(& (Get-Module Gangplank) { Get-GangplankTrustedGitLabHosts }).Count -eq 0) 'No GitLab host may be trusted by default'
    Assert (-not (& (Get-Module Gangplank) { [bool](Get-Variable -Name GangplankLegacyAliases -Scope Script -ErrorAction SilentlyContinue) })) 'No legacy GitLab host may be trusted'
    $rejected = $false
    try { Assert-GangplankTrustedRepositoryUrl -Url 'https://gitlab.example.org/group/project' } catch { $rejected = $true }
    Assert $rejected 'An unconfigured GitLab host must be refused'
    $noHost = $false
    try { [void](New-GangplankProvider -Provider GitLab) } catch { $noHost = ($_.Exception.Message -match 'GANGPLANK_GITLAB_HOST') }
    Assert $noHost 'A GitLab provider without a base URL or configured host must explain the setting'
    $env:GANGPLANK_GITLAB_HOST = 'https://GitLab.Example.org/'
    Assert ((& (Get-Module Gangplank) { Get-GangplankGitLabHost }) -eq 'gitlab.example.org') 'A configured URL should be reduced to its host'
    Assert-GangplankTrustedRepositoryUrl -Url 'https://gitlab.example.org/group/project'
    Assert ((@(& (Get-Module Gangplank) { Get-GangplankTrustedGitLabHosts }) -join ',') -eq 'gitlab.example.org') 'Only the configured host is trusted'
    $env:GANGPLANK_GITLAB_HOST = 'Git-Lab.example.org'
    Assert ((& (Get-Module Gangplank) { Get-GangplankGitLabHost }) -eq 'git-lab.example.org') 'A bare host name is accepted and lower-cased'
    Assert-GangplankTrustedRepositoryUrl -Url 'https://git-lab.example.org/group/project'
    $rejected = $false
    try { Assert-GangplankTrustedRepositoryUrl -Url 'https://other.example.org/group/project' } catch { $rejected = $true }
    Assert $rejected 'A host other than the configured one must be refused'
    foreach ($bad in @('gitlab.example.org/group','gitlab.example.org:8443','user@gitlab.example.org','gitlab example.org','gitlab_example.org')) {
        $env:GANGPLANK_GITLAB_HOST = $bad
        $msg = ''
        try { [void](& (Get-Module Gangplank) { Get-GangplankGitLabHost }) } catch { $msg = $_.Exception.Message }
        Assert ($msg -match 'letters, digits, dots and hyphens') ("A bad GitLab host must be rejected with a clear error: " + $bad)
    }
} finally { $env:GANGPLANK_GITLAB_HOST = $savedGitLabHost; $env:GANGPLANK_GITLAB_ALLOWED_HOSTS = $savedAllowed }
foreach ($url in @('http://github.com/a/b','https://github.com.evil.invalid/a/b','https://localhost/a/b','https://user:secret@github.com/a/b')) {
    $rejected = $false
    try { Assert-GangplankTrustedRepositoryUrl -Url $url } catch { $rejected = $true }
    Assert $rejected ("Untrusted URL: " + $url)
}
Assert (Test-GangplankSensitivePath -Path '.env') '.env protection'
Assert (Test-GangplankSensitivePath -Path 'config/credentials.json') 'Credentials filename protection'
Assert (-not (Test-GangplankSensitivePath -Path 'src/Hello.ps1')) 'Source file permitted'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    $keep = Join-Path $temp 'keep.txt'
    [IO.File]::WriteAllText($keep,'DO NOT DELETE')
    $fake = [pscustomobject]@{ DefaultBranch = 'main' }
    $refused = $false
    try { Invoke-GangplankPull -Session $fake -Branch main -LocalPath $temp | Out-Null } catch { $refused = $true }
    Assert $refused 'Nonempty download target must be refused'
    Assert (([IO.File]::ReadAllText($keep)) -eq 'DO NOT DELETE') 'Files must be preserved'
    $provider = New-Object psobject -Property @{ CurrentHead = 'abc123' }
    $provider | Add-Member -MemberType ScriptMethod -Name GetRefSha -Value { param($project,$branch) return $this.CurrentHead }
    $provider | Add-Member -MemberType ScriptMethod -Name InvokeApi -Value {
        param($method,$path,$body)
        if ($method -ne 'POST' -or $path -notmatch '/git/refs$' -or $body.ref -notmatch '^refs/heads/gangplank/work-') { throw 'Unexpected work branch creation' }
        return @{ ref = $body.ref; object = @{ sha = $body.sha } }
    }
    $session = [pscustomobject]@{
        Provider = 'GitHub'; ProviderObj = $provider; ProjectPath = 'team/demo'
        DefaultBranch = 'main'; LastBranch = 'main'; LocalPath = $temp
        BaselineSha = 'abc123'; BaselineMap = @{ 'keep.txt' = 'old-hash'; 'gone.txt' = 'previous-hash' }
    }
    $preview = Get-GangplankWorkspacePreview -Session $session
    Assert (-not $preview.RemoteChanged) 'False stale detection'
    Assert (@($preview.Changes | Where-Object { $_.Kind -eq 'Modified' }).Count -eq 1) 'Modified file missing'
    Assert (@($preview.Changes | Where-Object { $_.Kind -eq 'Deleted' -and $_.Selected }).Count -eq 0) 'Deletion auto-selected'
    $name = New-GangplankWorkBranch -Session $session
    Assert ($name -match '^gangplank/work-') 'Generated work branch name invalid'
    Assert (-not $session.BaselineSha) 'Branch creation must clear baseline'
    $session.LastBranch = 'main'; $session.BaselineSha = 'abc123'; $session.LocalPath = $temp
    $provider.CurrentHead = 'other'
    Assert (Get-GangplankWorkspacePreview -Session $session).RemoteChanged 'Remote update undetected'
    $blocked = $false
    try { Invoke-GangplankWorkspaceSave -Session $session -SelectedPaths @('keep.txt') | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Stale workspace saved unexpectedly'
} finally {
    Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue
}
$one = New-GangplankSmartMessage -Added @('src/New.ps1')
Assert ($one.HasChanges -and $one.Title -match '^feat') 'Smart title invalid'
Assert (-not (New-GangplankSmartMessage).HasChanges) 'Empty save invalid'
Write-Host 'All Gangplank workspace tests passed.' -ForegroundColor Green
