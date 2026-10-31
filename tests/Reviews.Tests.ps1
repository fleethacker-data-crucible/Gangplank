#Requires -Version 5.1
# Offline checks for review requests: numbers, open-only lookup, the merge guards
# (explicit confirmation and a full head sha) and comment limits. The GitHub provider
# is a subclass whose one read is scripted; every refusal is checked before any write.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$module = Get-Module Gangplank
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    Initialize-GangplankLogging -LogDir (Join-Path ([IO.Path]::GetTempPath()) 'gangplank-test-logs') -Level ERROR

    Invoke-Expression @'
class GangplankFakeReviewGitHub : GitHubProvider {
    [System.Collections.Generic.List[object]]$Calls
    GangplankFakeReviewGitHub() : base('https://api.github.com','test-token') {
        $this.Calls = New-Object System.Collections.Generic.List[object]
    }
    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body, [string]$outFile) {
        $this.Calls.Add([pscustomobject]@{ Method = $method; Endpoint = $endpoint })
        if ($endpoint -like 'repos/team/demo/pulls?state=open*') {
            return @([pscustomobject]@{
                number = 5; title = 'Review: work'; html_url = 'https://github.example.test/team/demo/pull/5'
                head = [pscustomobject]@{ ref = 'work' }; base = [pscustomobject]@{ ref = 'main' }
                user = [pscustomobject]@{ login = 'reviewer' }
            })
        }
        throw 'NETWORK|Unexpected call in the offline review test.'
    }
}
'@

    $provider = [GangplankFakeReviewGitHub]::new()
    $session = [pscustomobject]@{
        Provider = 'GitHub'; ProviderObj = $provider; ProjectPath = 'team/demo'
        DefaultBranch = 'main'; LastBranch = 'work'; Branches = @('main','work')
    }
    $sha = ('a' * 40)

    # Numbers are positive integers only.
    foreach ($bad in @('0','-1','5x','abc','')) {
        $code = ''
        try { [void](Get-GangplankReviewDetail -Session $session -Number $bad) } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
        Assert ($code -eq 'BAD_REQUEST') ("Review number must be refused: '$bad' ($code)")
    }

    # Only reviews the project lists as open can be read, commented on or merged.
    $code = ''
    try { [void](Get-GangplankReviewDetail -Session $session -Number 99) } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'NOT_FOUND') "A review that is not open must be NOT_FOUND, got $code"

    # Merge: explicit confirmation first, then a full head sha. Both refused before any write.
    $code = ''
    try { Merge-GangplankReview -Session $session -Number 5 -Sha $sha -Confirmed $false } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'BAD_REQUEST') 'A merge without confirmation must be refused'
    $code = ''
    try { Merge-GangplankReview -Session $session -Number 5 -Sha 'abc123' -Confirmed $true } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'BAD_REQUEST') 'A short sha must be refused'
    Assert (@($provider.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0) 'No write may happen on any refusal'

    # Comments: plain text, 1 to 4000 characters.
    # An empty comment is refused by parameter binding (Mandatory rejects ''); a long one by the coded check.
    $refused = $false
    try { Add-GangplankReviewComment -Session $session -Number 5 -Text '' } catch { $refused = $true }
    Assert $refused 'An empty comment must be refused'
    $code = ''
    try { Add-GangplankReviewComment -Session $session -Number 5 -Text ('x' * 4001) } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'BAD_REQUEST') "A comment over 4000 characters must be refused, got $code"
    Assert (@($provider.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0) 'No comment may be written on any refusal'
}
Write-Host 'Review request checks passed.' -ForegroundColor Green
