#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Core/RepositoryInsights.ps1')
function Assert($ok,[string]$msg){if(-not $ok){throw "FAIL: $msg"}}
$github=[pscustomobject]@{}
$github | Add-Member ScriptMethod GetBranches { param($p) return @('main','feature/test') }
$github | Add-Member ScriptMethod InvokeApi {
    param($m,$path)
    if($path -match '/compare/') {return [pscustomobject]@{ahead_by=2;behind_by=1;files=@([pscustomobject]@{filename='src/app.ps1';status='modified';additions=4;deletions=2})}}
    if($path -match '/pulls\?') {return @([pscustomobject]@{number=4;title='Fix';head=[pscustomobject]@{ref='feature/test'};base=[pscustomobject]@{ref='main'};user=[pscustomobject]@{login='tester'};html_url='https://github.com/example/repo/pull/4'},[pscustomobject]@{number=5;title='No user';head=$null;base=$null;user=$null;html_url='https://github.com/example/repo/pull/5'})}
    if($path -match '/commits\?') {return @([pscustomobject]@{sha='abc123';commit=[pscustomobject]@{message='Update app';author=[pscustomobject]@{name='Test';date='2026-10-23'}};html_url='https://github.com/example/repo/commit/abc123'})}
    throw "Unexpected API call $path"
}
$session=[pscustomobject]@{Provider='GitHub';ProviderObj=$github;ProjectPath='example/repo';DefaultBranch='main';LastBranch='feature/test'}
Assert (@(Get-GangplankRepositoryBranches -Session $session).Count -eq 2) 'Branch list'
Assert (@(Get-GangplankRepositoryHistory -Session $session).Count -eq 1) 'History'
$cmp=Get-GangplankRepositoryComparison -Session $session -Base main -Head 'feature/test'
Assert ($cmp.AheadBy -eq 2 -and @($cmp.Files).Count -eq 1) 'Compare'
$reviews=@(Get-GangplankRepositoryReviews -Session $session)
Assert ($reviews.Count -eq 2 -and $reviews[1].Author -eq '' -and $reviews[1].Source -eq '') 'A review with no user or branches still lists'
$ins=Get-GangplankRepositoryInsights -Session $session
Assert ($ins.OpenReviewCount -eq 2 -and $ins.BranchCount -eq 2 -and $ins.Suggestions.Count -ge 2) 'Insights'
$bad=$false
try { [void](Get-GangplankRepositoryComparison -Session $session -Base main -Head '../bad') } catch { $bad=$_.Exception.Message }
Assert ($bad -match '^BAD_REQUEST\|') ("Unknown branches must be a coded error: $bad")
Write-Host 'Repository insights mock tests passed.' -ForegroundColor Green
