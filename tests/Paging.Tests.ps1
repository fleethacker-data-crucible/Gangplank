#Requires -Version 5.1
# Offline checks for list paging: Link and X-Next-Page headers, the same-host rule,
# the page cap, and branch listing through both providers. The HTTP transport is a
# scripted fake, so no network is used.
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
    # A JSON array of branch objects named <prefix>1 .. <prefix>N.
    function Branches([int]$Count,[string]$Prefix = 'b') {
        $items = @()
        for ($i = 1; $i -le $Count; $i++) { $items += ('{"name":"' + $Prefix + $i + '"}') }
        return ('[' + ($items -join ',') + ']')
    }

    # --- Header parsing ----------------------------------------------------
    $link = @{ link = '<https://api.example.test/x?per_page=100&page=2>; rel="next", <https://api.example.test/x?per_page=100&page=9>; rel="last"' }
    $r = Get-GangplankNextPageUri -Headers $link -CurrentUri 'https://api.example.test/x?per_page=100&page=1'
    Assert ($r.Uri -eq 'https://api.example.test/x?per_page=100&page=2') ("Link rel=next not read: " + $r.Uri)
    Assert $r.Known 'A Link header means the paging is known'

    $r = Get-GangplankNextPageUri -Headers @{ link = '<https://api.example.test/x?page=1>; rel="prev"' } -CurrentUri 'https://api.example.test/x?page=2'
    Assert ($null -eq $r.Uri) 'A last page (prev only) has no next page'
    Assert $r.Known 'A last page with a Link header is still known'

    $r = Get-GangplankNextPageUri -Headers @{ 'x-next-page' = '3' } -CurrentUri 'https://gl.example.test/api/v4/projects/1/repository/branches?per_page=100&page=2'
    Assert ($r.Uri -eq 'https://gl.example.test/api/v4/projects/1/repository/branches?per_page=100&page=3') ("X-Next-Page not applied: " + $r.Uri)

    $r = Get-GangplankNextPageUri -Headers @{ 'x-next-page' = '' } -CurrentUri 'https://gl.example.test/api/v4/x?page=1'
    Assert ($null -eq $r.Uri) 'An empty X-Next-Page means the last page'

    $r = Get-GangplankNextPageUri -Headers @{} -CurrentUri 'https://api.example.test/x?page=1'
    Assert (-not $r.Known -and $null -eq $r.Uri) 'No paging headers: unknown, no next page'

    # --- Following pages -------------------------------------------------------
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 (Branches 100 'a') @{ link = '<https://api.example.test/repos/o/r/branches?per_page=100&page=2>; rel="next"' }))
    $script:Plan.Enqueue((Reply 200 (Branches 100 'b') @{ link = '<https://api.example.test/repos/o/r/branches?per_page=100&page=3>; rel="next"' }))
    $script:Plan.Enqueue((Reply 200 (Branches 50 'c') @{}))
    $all = @(Invoke-GangplankPagedGet -Provider 'GitHub' -Uri 'https://api.example.test/repos/o/r/branches?per_page=100' -Headers @{ Authorization = 'Bearer t' })
    Assert ($all.Count -eq 250) "Three Link pages should give 250 items, got $($all.Count)"
    Assert ($script:Seen.Count -eq 3) "Three requests expected, got $($script:Seen.Count)"
    Assert ($script:Seen[2].Uri -match 'page=3') 'The third request must be page 3'
    Assert ($script:Seen[2].Headers['Authorization'] -eq 'Bearer t') 'Auth must be sent on every page of the same host'

    # A paging link to another host is refused: the token never goes there.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 (Branches 2) @{ link = '<https://elsewhere.example.test/x?page=2>; rel="next"' }))
    $msg = ''
    try { [void](Invoke-GangplankPagedGet -Provider 'GitHub' -Uri 'https://api.example.test/repos/o/r/branches?per_page=100' -Headers @{}) } catch { $msg = [string]$_.Exception.Message }
    Assert ($msg -match '^NETWORK\|') ("Cross-host paging link must be refused: $msg")
    Assert ($script:Seen.Count -eq 1) 'The cross-host page must not be requested'

    # No paging headers, but a full page: keep asking for page=N until a short page.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 (Branches 100 'a')))
    $script:Plan.Enqueue((Reply 200 (Branches 5 'b')))
    $all = @(Invoke-GangplankPagedGet -Provider 'GitLab' -Uri 'https://gl.example.test/api/v4/projects/1/repository/branches?per_page=100' -Headers @{})
    Assert ($all.Count -eq 105) "Count-based paging should give 105 items, got $($all.Count)"
    Assert ($script:Seen[1].Uri -match 'page=2') 'Count-based paging must request page 2'

    # The page cap stops a list that never ends.
    $script:Seen.Clear(); $script:Plan.Clear()
    for ($i = 0; $i -lt 5; $i++) { $script:Plan.Enqueue((Reply 200 (Branches 1 ("p$i")) @{ link = '<https://api.example.test/repos/o/r/branches?page=99>; rel="next"' })) }
    $all = @(Invoke-GangplankPagedGet -Provider 'GitHub' -Uri 'https://api.example.test/repos/o/r/branches?per_page=100' -Headers @{} -MaxPages 3)
    Assert ($script:Seen.Count -eq 3) "The cap must stop after 3 pages, requested $($script:Seen.Count)"
    Assert ($all.Count -eq 3) 'Items from the pages fetched before the cap are kept'

    # An empty page ends the list.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 '[]' @{ link = '<https://api.example.test/repos/o/r/branches?page=2>; rel="next"' }))
    $all = @(Invoke-GangplankPagedGet -Provider 'GitHub' -Uri 'https://api.example.test/repos/o/r/branches' -Headers @{})
    Assert ($all.Count -eq 0 -and $script:Seen.Count -eq 1) 'An empty page stops the list'

    # --- Providers list branches across pages -------------------------------
    $gh = [GitHubProvider]::new('https://api.github.com','tok-gh')
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 (Branches 100 'g') @{ link = '<https://api.github.com/repos/team/demo/branches?per_page=100&page=2>; rel="next"' }))
    $script:Plan.Enqueue((Reply 200 (Branches 2 'h') @{}))
    $names = @($gh.GetBranches('team/demo'))
    Assert ($names.Count -eq 102) "GitHub GetBranches should list every page, got $($names.Count)"
    Assert ($names[101] -eq 'h2') 'GitHub GetBranches keeps the last page'
    Assert ($script:Seen[0].Headers['Authorization'] -eq 'Bearer tok-gh') 'GitHub branch list must send the token'

    $gl = [GitLabProvider]::new('https://gl.example.test','tok-gl')
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 200 (Branches 100 'g') @{ 'x-next-page' = '2' }))
    $script:Plan.Enqueue((Reply 200 (Branches 3 'h') @{ 'x-next-page' = '' }))
    $names = @($gl.GetBranches('team/sub/demo'))
    Assert ($names.Count -eq 103) "GitLab GetBranches should list every page, got $($names.Count)"
    Assert ($script:Seen[0].Uri -match '/projects/team%2Fsub%2Fdemo/repository/branches\?per_page=100') ("GitLab project path must be encoded: " + $script:Seen[0].Uri)
    Assert ($script:Seen[0].Headers['PRIVATE-TOKEN'] -eq 'tok-gl') 'GitLab branch list must send the private token'

    $script:GangplankHttpTransport = $null
    $script:GangplankHttpSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
}
Write-Host 'Paging checks passed.' -ForegroundColor Green
