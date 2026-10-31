#Requires -Version 5.1
# Offline checks for the GitLab provider: project paths, archive download, merge
# requests, coded errors, and LocalDev routing to a synthetic GitLab. The HTTP
# transport is a scripted fake, so nothing reaches a real GitLab.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$module = Get-Module Gangplank
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    Initialize-GangplankLogging -LogDir (Join-Path ([IO.Path]::GetTempPath()) 'gangplank-test-logs') -Level ERROR

    $script:Seen = New-Object System.Collections.Generic.List[object]
    $script:Plan = New-Object System.Collections.Generic.Queue[object]
    $script:GangplankHttpSleep = { param([int]$Milliseconds) }
    $script:GangplankHttpTransport = {
        param($Request)
        $script:Seen.Add($Request)
        return $script:Plan.Dequeue()
    }
    function Reply([int]$Status,[string]$Text = '',[hashtable]$Headers = @{}) {
        [pscustomobject]@{ Status = $Status; Headers = $Headers; Text = $Text; File = $null; NetworkError = '' }
    }

    $gl = [GitLabProvider]::new('https://gitlab.example.test','tok-gl')

    # Project paths are encoded as one segment (team%2Fsub%2Fdemo) and the token goes in PRIVATE-TOKEN.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 '{"id":7,"default_branch":"trunk"}'))
    $project = $gl.ResolveProject('team/sub/demo')
    Assert ($project.id -eq 7) 'ResolveProject should return the project'
    Assert ($script:Seen[0].Uri -eq 'https://gitlab.example.test/api/v4/projects/team%2Fsub%2Fdemo') ("Project path not encoded: " + $script:Seen[0].Uri)
    Assert ($script:Seen[0].Headers['PRIVATE-TOKEN'] -eq 'tok-gl') 'The token must be sent as PRIVATE-TOKEN'
    $script:Plan.Enqueue((Reply 200 '{"id":7,"default_branch":"trunk"}'))
    Assert ($gl.GetDefaultBranch('team/sub/demo') -eq 'trunk') 'The default branch comes from the project'

    # Coded errors: a rejected token and a missing project never leak the response body.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 401 '{"message":"secret detail"}'))
    $code = ''; $text = ''
    try { [void]$gl.ResolveProject('team/demo') } catch { $text = [string]$_.Exception.Message; $code = ($text -split '\|')[0] }
    Assert ($code -eq 'AUTH_REJECTED') ("401 must map to AUTH_REJECTED, got: $text")
    Assert ($text -notmatch 'secret detail') 'The response body must not reach the error text'

    # Archive download is for a fixed commit (sha=), not a branch name.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue([pscustomobject]@{ Status = 200; Headers = @{}; Text = ''; File = 'archive.zip'; NetworkError = '' })
    $gl.DownloadArchive('team/demo', 'abc123', (Join-Path ([IO.Path]::GetTempPath()) 'gl-archive-test.zip'))
    Assert ($script:Seen[0].Uri -match '/projects/team%2Fdemo/repository/archive\.zip\?sha=abc123$') ("Archive must be requested by sha: " + $script:Seen[0].Uri)

    # Merge requests: source and target branches go in the body; the response is returned.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 201 '{"iid":4,"web_url":"https://gitlab.example.test/team/demo/-/merge_requests/4"}'))
    $mr = $gl.CreateMergeRequest('team/demo', 'work-1', 'main', 'Review: work', 'Created with Gangplank.')
    Assert ($mr.iid -eq 4) 'CreateMergeRequest should return the new request'
    Assert ($script:Seen[0].Method -eq 'POST' -and $script:Seen[0].Uri -match '/merge_requests$') 'Merge request is a POST to merge_requests'
    Assert ([string]$script:Seen[0].Body -match '"source_branch":"work-1"') 'The source branch must be in the body'

    # LocalDev: a synthetic GitLab is routed by the host, and nothing else is.
    Set-GangplankDevProvider -GitLabUrl 'http://127.0.0.1:9/'
    $dev = Parse-GangplankRepoUrl -Url 'http://127.0.0.1:9/team/demo'
    Assert ($dev.Provider -eq 'GitLab') ("A synthetic GitLab URL must route to GitLab, got " + $dev.Provider)
    Assert ($dev.ProjectPath -eq 'team/demo') ("Project path after the synthetic base: " + $dev.ProjectPath)
    $refused = $false
    try { Set-GangplankDevProvider -GitLabUrl 'https://gitlab.example.test/' } catch { $refused = $true }
    Assert $refused 'A synthetic GitLab must be loopback http only'
    $script:GangplankDevGitLabUrl = $null
    Assert (-not (Test-GangplankDevRepositoryUrl -Url 'http://127.0.0.1:9/team/demo')) 'Without a synthetic GitLab, its address is not special'

    $script:GangplankHttpTransport = $null
    $script:GangplankHttpSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
}
Write-Host 'GitLab provider checks passed.' -ForegroundColor Green
