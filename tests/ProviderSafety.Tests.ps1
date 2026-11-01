#Requires -Version 5.1
# Offline checks for GitHub provider error handling, branch-ref encoding, file-mode
# preservation on Smart Save, browser-safe error text and launcher hardening.
# No credentials or network: the GitHub API is a scripted in-memory fake.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$module = Get-Module Gangplank
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    Initialize-GangplankLogging -LogDir (Join-Path ([IO.Path]::GetTempPath()) 'gangplank-test-logs') -Level ERROR

    # A GitHubProvider whose InvokeApi is answered by a script block, so the real
    # class methods (GetRefSha, GetPathModes, CreateTree...) run unchanged.
    Invoke-Expression @'
class GangplankFakeGitHub : GitHubProvider {
    [scriptblock]$Handler
    [System.Collections.Generic.List[object]]$Calls
    GangplankFakeGitHub([scriptblock]$handler) : base('https://api.github.com','test-token') {
        $this.Handler = $handler
        $this.Calls = New-Object System.Collections.Generic.List[object]
    }
    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body, [string]$outFile) {
        $this.Calls.Add([pscustomobject]@{ Method = $method; Endpoint = $endpoint; Body = $body })
        return (& $this.Handler $method $endpoint $body)
    }
}
'@
    $script:FakeType = 'GangplankFakeGitHub' -as [type]
    Assert ($null -ne $script:FakeType) 'Fake provider type must load'

    # --- GetRefSha: 404 means "no branch", anything else must surface ---------
    $p404 = $script:FakeType::new({ param($m,$e,$b) throw 'NOT_FOUND|GitHub API GET x failed (HTTP 404).' })
    Assert (-not $p404.GetRefSha('team/demo','missing')) '404 should mean the branch does not exist'
    $p401 = $script:FakeType::new({ param($m,$e,$b) throw 'AUTH_REJECTED|GitHub API GET x failed (HTTP 401).' })
    $threw = $false
    try { [void]$p401.GetRefSha('team/demo','main') } catch { $threw = $true }
    Assert $threw '401 must not be reported as a missing or moved branch'

    # --- Branch names are encoded per segment, slashes kept -------------------
    $pRef = $script:FakeType::new({ param($m,$e,$b) return @{ object = @{ sha = 'abc' } } })
    [void]$pRef.GetRefSha('team/demo','feature/a b#1')
    Assert ($pRef.Calls[0].Endpoint -eq 'repos/team/demo/git/ref/heads/feature/a%20b%231') ("Ref path not encoded: " + $pRef.Calls[0].Endpoint)
    Assert ((ConvertTo-GangplankRefPath -Ref 'gangplank/work-1') -eq 'gangplank/work-1') 'Plain branch names must be unchanged'

    # --- Error bodies never reach the browser text ----------------------------
    $safe = Get-GangplankSafeErrorMessage -Message ("GitHub API POST repos/x failed (HTTP 422) | {`"message`":`"secret detail`"}" + [char]10 + 'second line')
    Assert ($safe -notmatch 'secret detail') 'Provider response body leaked into browser error'
    Assert ($safe -notmatch "`n") 'Browser error must be a single line'
    Assert ((Get-GangplankSafeErrorMessage -Message 'LAZARETTE_LOCKED|Lazarette was found but the vault is locked.') -match '^LAZARETTE_LOCKED\|') 'Coded errors must keep their code'

    # --- Transport: retries, writes, redirects, coded errors -----------------
    $script:GangplankHttpSleep = { param($ms) $script:Slept += $ms }
    $script:Slept = 0
    $script:Seen = New-Object System.Collections.Generic.List[object]
    $script:Plan = New-Object System.Collections.Generic.Queue[object]
    $script:GangplankHttpTransport = {
        param($Request)
        $script:Seen.Add($Request)
        return $script:Plan.Dequeue()
    }
    function Reply([int]$Status,[string]$Text = '',[hashtable]$Headers = @{}) { [pscustomobject]@{ Status = $Status; Headers = $Headers; Text = $Text; File = $null; NetworkError = $(if ($Status -eq 0) { 'ConnectFailure' } else { '' }) } }
    $gh = [GitHubProvider]::new('https://api.github.com','tok-123')

    $script:Seen.Clear(); $script:Plan.Enqueue((Reply 429 '{}' @{ 'retry-after' = '2' })); $script:Plan.Enqueue((Reply 502)); $script:Plan.Enqueue((Reply 200 '{"full_name":"team/demo"}'))
    $repo = $gh.InvokeApi('GET','repos/team/demo')
    Assert ($repo.full_name -eq 'team/demo') 'GET should succeed after retries'
    Assert ($script:Seen.Count -eq 3) "GET should be tried 3 times, was $($script:Seen.Count)"
    Assert ($script:Slept -ge 2000) 'Retry-After was not honoured'

    $script:Seen.Clear(); $script:Plan.Enqueue((Reply 502)); $script:Plan.Enqueue((Reply 200 '{}'))
    $code = ''
    try { [void]$gh.InvokeApi('POST','repos/team/demo/git/blobs',@{ content = 'x' }) } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($script:Seen.Count -eq 1) 'Writes must never be retried'
    Assert ($code -eq 'SERVER_ERROR') "502 should map to SERVER_ERROR, got $code"
    $script:Plan.Clear()

    foreach ($case in @(@(401,'AUTH_REJECTED',@{}),@(403,'FORBIDDEN',@{}),@(403,'RATE_LIMITED',@{ 'x-ratelimit-remaining' = '0' }),@(404,'NOT_FOUND',@{}),@(422,'CONFLICT',@{}))) {
        $script:Plan.Clear(); $script:Plan.Enqueue((Reply $case[0] '{"message":"provider secret detail"}' $case[2]))
        $msg = ''
        try { [void]$gh.InvokeApi('POST','repos/team/demo/pulls',@{}) } catch { $msg = [string]$_.Exception.Message }
        Assert ($msg -match ('^' + $case[1] + '\|')) ("HTTP $($case[0]) should map to $($case[1]): $msg")
        Assert ($msg -notmatch 'provider secret detail') 'Response body leaked into the error message'
    }

    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 302 '' @{ location = 'https://codeload.github.com/team/demo/legacy.zip/abc?token=signed' }))
    $script:Plan.Enqueue([pscustomobject]@{ Status = 200; Headers = @{}; Text = ''; File = 'x.zip'; NetworkError = '' })
    [void](Invoke-GangplankDownload -Provider GitHub -Uri 'https://api.github.com/repos/team/demo/zipball/abc' -AuthHeaders $gh.GetAuthHeaders('GET') -OutFile 'x.zip')
    Assert ($script:Seen[0].Headers['Authorization'] -eq 'Bearer tok-123') 'API host should get the token'
    Assert (-not $script:Seen[1].Headers.ContainsKey('Authorization')) 'Token must not follow a redirect to another host'
    Assert ($script:Seen[1].Uri -match '^https://codeload\.github\.com/') 'Redirect target not followed'

    $script:Seen.Clear(); $script:Plan.Clear(); $script:Plan.Enqueue((Reply 0)); $script:Plan.Enqueue((Reply 0)); $script:Plan.Enqueue((Reply 0))
    $msg = ''
    try { [void]$gh.InvokeApi('GET','repos/team/demo') } catch { $msg = [string]$_.Exception.Message }
    Assert ($msg -match '^NETWORK\|') "Network failure should be NETWORK: $msg"
    Assert ((Get-GangplankSafeUrl 'https://h.example/p/a?token=secret') -eq 'https://h.example/p/a') 'Safe URL must drop the query'
    # Same-host redirects are followed for reads (renamed repos); other hosts never get the token.
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 301 '' @{ location = 'https://api.github.com/repositories/42' })); $script:Plan.Enqueue((Reply 200 '{"full_name":"team/renamed"}'))
    Assert (($gh.InvokeApi('GET','repos/team/old')).full_name -eq 'team/renamed') 'Same-host redirect not followed'
    Assert ($script:Seen[1].Headers['Authorization'] -eq 'Bearer tok-123') 'Same-host redirect should keep auth'
    $script:Seen.Clear(); $script:Plan.Clear()
    $script:Plan.Enqueue((Reply 302 '' @{ location = 'https://elsewhere.example/x' }))
    $msg = ''
    try { [void]$gh.InvokeApi('GET','repos/team/x') } catch { $msg = [string]$_.Exception.Message }
    Assert ($script:Seen.Count -eq 1) 'A redirect to another host must not be followed with the token'
    Assert ($msg -match '^HTTP_302\|') "Cross-host API redirect should fail, got: $msg"

    # Requests answered on the HTTP loop fail fast: one attempt, short timeout.
    $script:Seen.Clear(); $script:Plan.Clear(); $script:Plan.Enqueue((Reply 502)); $script:Plan.Enqueue((Reply 200 '{}'))
    $script:GangplankHttpInteractive = $true
    try { try { [void]$gh.InvokeApi('GET','repos/team/demo') } catch { } } finally { $script:GangplankHttpInteractive = $false }
    Assert ($script:Seen.Count -eq 1) 'Interactive reads must not retry'
    Assert ($script:Seen[0].TimeoutSec -le 20) 'Interactive reads must use a short timeout'
    $script:Plan.Clear()

    $script:GangplankHttpTransport = $null
    $script:GangplankHttpSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }

    # --- Session snapshots and restore -----------------------------------------
    $live = [pscustomobject]@{ Provider = 'GitHub'; BaseUrl = 'https://github.com'; ProjectPath = 'team/demo'; DefaultBranch = 'main'; BaselineMap = @{ 'a.txt' = 'h1' } }
    $snap = ConvertTo-GangplankSessionSnapshot $live
    $snap.BaselineMap['b.txt'] = 'h2'
    Assert (-not $live.BaselineMap.ContainsKey('b.txt')) 'Snapshots must copy the baseline map, not share it across threads'
    $sessDir = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-sess-' + [guid]::NewGuid().ToString('N'))
    try {
        Save-GangplankSessionState -StateRoot $sessDir -Session $live
        Assert ($null -ne (Read-GangplankSessionState -StateRoot $sessDir)) 'A github.com session should restore'
        $devLike = [pscustomobject]@{ Provider = 'GitHub'; BaseUrl = 'http://127.0.0.1:8791'; ProjectPath = 'gangplank-demo/sample'; DefaultBranch = 'main'; BaselineMap = @{} }
        Save-GangplankSessionState -StateRoot $sessDir -Session $devLike
        $script:GangplankDevGitHubUrl = $null
        Assert ($null -eq (Read-GangplankSessionState -StateRoot $sessDir)) 'A LocalDev session must never restore in a normal run'
    } finally { Remove-Item -LiteralPath $sessDir -Recurse -Force -ErrorAction SilentlyContinue }

    # --- GetPathModes walks only the needed directories ------------------------
    $trees = @{
        'root' = @{ tree = @(
            @{ path = 'build.sh'; mode = '100755'; type = 'blob'; sha = 'b1' },
            @{ path = 'README.md'; mode = '100644'; type = 'blob'; sha = 'b2' },
            @{ path = 'tools'; mode = '040000'; type = 'tree'; sha = 'tools' },
            @{ path = 'docs'; mode = '040000'; type = 'tree'; sha = 'docs' }) }
        'tools' = @{ tree = @(@{ path = 'run.ps1'; mode = '100755'; type = 'blob'; sha = 'b3' }) }
        'docs' = @{ tree = @(@{ path = 'a.md'; mode = '100644'; type = 'blob'; sha = 'b4' }) }
    }
    $pModes = $script:FakeType::new({
        param($m,$e,$b)
        if ($m -eq 'GET' -and $e -match '/git/trees/(.+)$') { return $trees[$Matches[1]] }
        throw "Unexpected call $m $e"
    }.GetNewClosure())
    $modes = $pModes.GetPathModes('team/demo','root',@('build.sh','tools/run.ps1','README.md','tools/missing.txt'))
    Assert ($modes['build.sh'] -eq '100755') 'Root executable mode lost'
    Assert ($modes['tools/run.ps1'] -eq '100755') 'Nested executable mode lost'
    Assert ($modes['README.md'] -eq '100644') 'Regular mode lost'
    Assert (-not $modes.ContainsKey('tools/missing.txt')) 'Unknown path must not get a mode'
    Assert (@($pModes.Calls | Where-Object { $_.Endpoint -match '/git/trees/docs$' }).Count -eq 0) 'Unrelated directory was listed'

    # --- Smart Save keeps the executable bit end to end ------------------------
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-save-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $temp)
    try {
        [IO.File]::WriteAllText((Join-Path $temp 'build.sh'),"echo old`n")
        [IO.File]::WriteAllText((Join-Path $temp 'README.md'),"old`n")
        $baseline = Get-GangplankLocalFileMap -Root $temp
        [IO.File]::WriteAllText((Join-Path $temp 'build.sh'),"echo new`n")
        [IO.File]::WriteAllText((Join-Path $temp 'notes.txt'),"new file`n")
        $state = @{ Head = 'c0'; Tree = $null; Ref = $null }
        $saveTrees = @{ 'root' = @{ tree = @(
            @{ path = 'build.sh'; mode = '100755'; type = 'blob'; sha = 'b1' },
            @{ path = 'README.md'; mode = '100644'; type = 'blob'; sha = 'b2' }) } }
        $pSave = $script:FakeType::new({
            param($m,$e,$b)
            switch -Regex ($e) {
                '^repos/team/demo$' { return @{ private = $true; visibility = 'private' } }
                '/git/ref/heads/' { return @{ object = @{ sha = $state.Head } } }
                '/git/commits/c0$' { return @{ tree = @{ sha = 'root' } } }
                '/git/trees/root$' { return $saveTrees['root'] }
                '/git/blobs$' { return @{ sha = 'newblob' } }
                '/git/trees$' { $state.Tree = $b; return @{ sha = 't1' } }
                '/git/commits$' { return @{ sha = 'c1' } }
                '/git/refs/heads/' { $state.Ref = $b; return @{} }
            }
            throw "Unexpected call $m $e"
        }.GetNewClosure())
        $session = [pscustomobject]@{
            Provider = 'GitHub'; ProviderObj = $pSave; ProjectPath = 'team/demo'
            DefaultBranch = 'main'; LastBranch = 'gangplank/work-1'; LocalPath = $temp
            BaselineSha = 'c0'; BaselineMap = $baseline
        }
        $saved = Invoke-GangplankWorkspaceSave -Session $session -SelectedPaths @('build.sh','notes.txt') -Message 'update build script'
        Assert ($saved.Commit -eq 'c1') 'Save did not commit'
        $tree = $state.Tree | ConvertFrom-Json
        $entry = @($tree.tree | Where-Object { $_.path -eq 'build.sh' })[0]
        $new = @($tree.tree | Where-Object { $_.path -eq 'notes.txt' })[0]
        Assert ($entry.mode -eq '100755') ("Executable bit dropped on save: " + $entry.mode)
        Assert ($new.mode -eq '100644') 'New file should be a regular file'
        Assert ($state.Ref.force -eq $false) 'Branch update must never be forced'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Host hardening (text checks; behaviour is covered by tests/e2e/host.e2e.mjs) ---
$host1 = [IO.File]::ReadAllText((Join-Path $root 'Start-Gangplank.ps1'))
$http = [IO.File]::ReadAllText((Join-Path $root 'Server/Http.ps1'))
$routes = [IO.File]::ReadAllText((Join-Path $root 'Server/Routes.ps1'))
foreach ($text in @($host1,$http,$routes)) {
    Assert ($text -notmatch 'GANGPLANK_LOCAL_DEV') 'No environment variable may switch the host into LocalDev'
}
Assert ($http -match 'TcpListener') 'Host must use TcpListener (TechStack), not HttpListener'
Assert ($http -notmatch 'HttpListener') 'HttpListener must be gone'
Assert ($http -notmatch "unsafe-inline|unsafe-eval") 'CSP must not allow inline script or style'
Assert ($http -match 'HttpOnly; SameSite=Strict') 'Session cookie must be HttpOnly and SameSite=Strict'
Assert ($routes -match 'Split-GangplankCodedMessage') 'Route errors must go through the safe error filter'
Assert ($routes -notmatch '\$_\.Exception\.Message\s*\}') 'Raw exception text must not be sent to the browser'
# Every Gangplank function the launcher calls must be exported by the module.
$exported = @((Get-Module Gangplank).ExportedFunctions.Keys)
$calls = @([regex]::Matches($host1,'\b[A-Z][a-z]+-Gangplank[A-Za-z]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
$unexported = @($calls | Where-Object { $_ -notin $exported })
Assert ($unexported.Count -eq 0) ('Launcher calls functions the module does not export: ' + ($unexported -join ', '))
# Every function the routes call must exist in the module.
$moduleCommands = @((& (Get-Module Gangplank) { Get-Command -Module Gangplank -CommandType Function | ForEach-Object Name }))
$routeCalls = @([regex]::Matches($routes + $http,'\b(?:Get|Set|New|Invoke|Test|Send|Read|Start|Stop|Remove|Save|Use|Split|Initialize|Assert|Parse|Resolve|ConvertTo|Update|Wait|Write)-Gangplank[A-Za-z]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
$missing = @($routeCalls | Where-Object { $_ -notin $moduleCommands -and $_ -notin @('Parse-GangplankRepoUrl') })
Assert ($missing.Count -eq 0) ('Routes call functions that do not exist: ' + ($missing -join ', '))
$ci = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/gangplank-ci.yml'))
Assert ($ci -notmatch 'GANGPLANK_LOCAL_DEV') 'CI must pass -LocalDev explicitly instead of an environment switch'
Write-Host 'Provider safety, file-mode and launcher hardening checks passed.' -ForegroundColor Green
