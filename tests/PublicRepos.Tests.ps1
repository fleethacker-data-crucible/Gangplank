#Requires -Version 5.1
# Public GitHub browsing without a token: organization and user/profile lists
# (including a second page), anonymous rate-limit text, and the authenticated
# path. The HTTP transport is in-memory. No network and no real token.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$saved = @{}
foreach ($n in @('GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_GITLAB_HOST','GANGPLANK_GITLAB_ALLOWED_HOSTS','GANGPLANK_LAZARETTE_PATH','LAZARETTE_PATH')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}

$module = Get-Module Gangplank
try {
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-public-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $config = Join-Path $temp 'gangplank-config.json'
    [IO.File]::WriteAllText($config, '{}')
    Initialize-GangplankLogging -LogDir (Join-Path $temp 'logs') -Level DEBUG
    Initialize-GangplankConfig -ConfigPath $config

    $script:Seen = New-Object System.Collections.Generic.List[object]
    $script:Plan = New-Object System.Collections.Generic.Queue[object]
    $script:GangplankHttpSleep = { param([int]$Milliseconds) }
    $script:GangplankHttpTransport = {
        param($Request)
        $script:Seen.Add($Request)
        if ($script:Plan.Count -eq 0) { throw 'HTTP transport ran out of scripted replies.' }
        return $script:Plan.Dequeue()
    }
    function Reply([int]$Status,[string]$Text = '',[hashtable]$Headers = @{}) {
        [pscustomobject]@{ Status = $Status; Headers = $Headers; Text = $Text; File = $null; NetworkError = '' }
    }
    function Repo([string]$Owner,[string]$Name,[string]$Private,[string]$Description) {
        return '{"name":"' + $Name + '","full_name":"' + $Owner + '/' + $Name + '","private":' + $Private + ',"description":"' + $Description + '","html_url":"https://evil.example/phish"}'
    }
    function Page([string[]]$Rows) { return ('[' + ($Rows -join ',') + ']') }
    function Reset { $script:Seen.Clear(); $script:Plan.Clear() }
    function NoAuth($Request,[string]$Why) {
        $hasAuth = $false
        foreach ($k in @($Request.Headers.Keys)) {
            if ([string]$k -eq 'Authorization') { $hasAuth = $true }
            Assert ([string]$Request.Headers[$k] -notmatch 'Bearer') $Why
        }
        Assert (-not $hasAuth) $Why
    }
    function EachSeen([scriptblock]$Body) {
        for ($i = 0; $i -lt $script:Seen.Count; $i++) { & $Body $script:Seen[$i] }
    }
    $token = 'test-token-value-do-not-leak'
    $log = $script:GangplankLogFile

    # --- Addresses --------------------------------------------------------------
    Assert-GangplankTrustedRepositoryUrl -Url 'https://github.com/acme'
    $owner = Resolve-GangplankConnectTarget -Url 'https://github.com/acme'
    Assert ($owner.Mode -eq 'owner' -and $owner.Owner -eq 'acme') 'A single GitHub segment is an owner'
    $org = Resolve-GangplankConnectTarget -Url 'https://github.com/orgs/acme/repositories'
    Assert ($org.Mode -eq 'organization' -and $org.Owner -eq 'acme') 'orgs/name/repositories is an organization'
    $user = Resolve-GangplankConnectTarget -Url 'https://github.com/users/ada?tab=repositories'
    Assert ($user.Mode -eq 'user' -and $user.Owner -eq 'ada') 'users/name?tab=repositories is a profile'
    $repo = Resolve-GangplankConnectTarget -Url 'https://github.com/acme/demo/tree/main'
    Assert ($repo.Mode -eq 'repository' -and $repo.ProjectPath -eq 'acme/demo') 'A repository URL keeps owner/name'
    $bad = ''
    try { Resolve-GangplankConnectTarget -Url 'https://github.com/orgs/acme/people' } catch { $bad = [string]$_.Exception.Message }
    Assert ($bad -match '^BAD_REQUEST\|') "An organization subpage must not be treated as a repository: $bad"
    $bad = ''
    try { Resolve-GangplankConnectTarget -Url 'https://github.com/orgs/-bad' } catch { $bad = [string]$_.Exception.Message }
    Assert ($bad -match '^BAD_REQUEST\|') "An invalid GitHub name must be refused: $bad"
    $embedded = $false
    try { Assert-GangplankTrustedRepositoryUrl -Url 'https://user:secret-token-value@github.com/acme/demo' } catch { $embedded = $true }
    Assert $embedded 'A URL with embedded credentials must be refused'

    # Strict resolution is unchanged. The optional helper is what public reads use.
    $missing = ''
    try { Resolve-GangplankCredential -Provider GitHub } catch { $missing = [string]$_.Exception.Message }
    Assert ($missing -match '^CREDENTIAL_MISSING\|') 'A missing GitHub token is still CREDENTIAL_MISSING for callers that require one'
    Assert ((Get-GangplankOptionalProviderToken -Provider GitHub) -eq '') 'Public GitHub reads may proceed with no token'
    $glMissing = ''
    try { Get-GangplankOptionalProviderToken -Provider GitLab } catch { $glMissing = [string]$_.Exception.Message }
    Assert ($glMissing -match '^CREDENTIAL_MISSING\|') 'GitLab still requires a token'

    # --- Anonymous organization list, two pages, no Authorization --------------
    Reset
    $next = '<https://api.github.com/orgs/acme/repos?per_page=100&type=public&page=2>; rel="next"'
    $script:Plan.Enqueue((Reply 200 (Page @(
        (Repo 'acme' 'one' 'false' 'First'),
        '{"name":"nope","full_name":"other/nope","private":false,"description":"wrong owner","html_url":"https://evil.example/phish"}'
    )) @{ link = $next }))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'acme' 'two' 'false' 'Second'))) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/orgs/acme' -Token ''
    Assert ($catalog.kind -eq 'organization' -and $catalog.name -eq 'acme' -and $catalog.anonymous) 'Anonymous organization catalog'
    Assert (@($catalog.repositories).Count -eq 2) 'Both pages of the organization list are kept'
    Assert ($catalog.repositories[0].fullName -eq 'acme/one' -and $catalog.repositories[1].fullName -eq 'acme/two') 'Page order is kept'
    Assert ($catalog.repositories[0].url -eq 'https://github.com/acme/one') 'Repository URL is built from the name, not html_url'
    $asJson = $catalog | ConvertTo-Json -Depth 6
    Assert ($asJson -notmatch 'evil\.example') 'A hostile html_url must not be returned'
    Assert ($script:Seen.Count -eq 2) 'Organization list is two requests'
    Assert ($script:Seen[0].Uri -match '/orgs/acme/repos\?per_page=100&type=public') ("Anonymous org list must ask for public repos: " + $script:Seen[0].Uri)
    Assert ($script:Seen[1].Uri -match 'page=2') 'The second organization page must be requested'
    NoAuth $script:Seen[0] 'Anonymous organization page 1 must not send Authorization'
    NoAuth $script:Seen[1] 'Anonymous organization page 2 must not send Authorization'

    # --- Anonymous user profile, probe plus two pages --------------------------
    Reset
    $script:Plan.Enqueue((Reply 200 '{"login":"ada","type":"User"}'))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'ada' 'notes' 'false' 'Notes'))) @{ link = '<https://api.github.com/users/ada/repos?per_page=100&type=owner&page=2>; rel="next"' }))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'ada' 'more' 'false' 'More'))) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/users/ada?tab=repositories' -Token ''
    Assert ($catalog.kind -eq 'user' -and $catalog.name -eq 'ada' -and $catalog.anonymous) 'Anonymous profile catalog'
    Assert (@($catalog.repositories).Count -eq 2) 'Both pages of the profile list are kept'
    Assert ($script:Seen.Count -eq 3) 'Profile list is a probe plus two pages'
    Assert ($script:Seen[0].Uri -match '/users/ada$') 'Profile probe is GET /users/{name}'
    Assert (@($script:Seen | Where-Object { $_.Uri -match '/user($|\?)' }).Count -eq 0) 'Anonymous profile listing must not call /user'
    EachSeen { param($req) NoAuth $req 'Anonymous profile requests must not send Authorization' }

    # A plain owner URL is classified by the API.
    Reset
    $script:Plan.Enqueue((Reply 200 '{"login":"acme","type":"Organization"}'))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'acme' 'lib' 'false' 'Lib'))) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/acme' -Token ''
    Assert ($catalog.kind -eq 'organization' -and $catalog.repositories[0].fullName -eq 'acme/lib') 'Owner URL of an organization lists its public repos'
    Assert ($script:Seen[1].Uri -match '/orgs/acme/repos\?') 'An organization owner uses the org repository API'
    NoAuth $script:Seen[1] 'Classified organization list is still anonymous'

    Reset
    $script:Plan.Enqueue((Reply 200 '{"login":"ada","type":"User"}'))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'ada' 'dot' 'false' 'Dot'))) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/ada' -Token ''
    Assert ($catalog.kind -eq 'user' -and $catalog.repositories[0].url -eq 'https://github.com/ada/dot') 'Owner URL of a user lists that profile'
    Assert ($script:Seen[1].Uri -match '/users/ada/repos\?') 'A user owner uses the user repository API'

    # --- Anonymous rate limit ---------------------------------------------------
    Reset
    $script:Plan.Enqueue((Reply 403 '{"message":"TOKEN_IN_BODY_SHOULD_NOT_SURFACE"}' @{ 'x-ratelimit-remaining' = '0'; 'x-ratelimit-limit' = '60'; 'x-ratelimit-reset' = '1700000000' }))
    $limited = ''
    try { Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/orgs/acme' -Token '' } catch { $limited = [string]$_.Exception.Message }
    Assert ($limited -match '^RATE_LIMITED\|') "Anonymous rate limit must stay RATE_LIMITED: $limited"
    Assert ($limited -match 'do not require a token') 'Rate limit text must say a token is not required'
    Assert ($limited -match 'optional token') 'Rate limit text must offer an optional token'
    Assert ($limited -match '60 per hour') 'Rate limit text must name the anonymous limit'
    Assert ($limited -match '2023-11-14 22:13 UTC') 'Rate limit text must include the reset time'
    Assert ($limited -notmatch 'TOKEN_IN_BODY_SHOULD_NOT_SURFACE') 'The provider body must not be shown'
    Assert ($limited -notmatch 'token is required|requires a personal|must have a token|PAT is required') 'Rate limit text must not say public access requires a token'
    $generic = Get-GangplankGitHubRateLimitMessage -Headers @{ 'x-ratelimit-limit' = '5000'; 'x-ratelimit-remaining' = '0' }
    Assert ($generic -match 'do not require a token') 'An authenticated limit still must not claim public access requires a token'
    Assert ($generic -notmatch 'token is required') 'Authenticated limit text must not require a token for public access'

    # The second page hitting the limit fails the list with the same explanation.
    Reset
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'acme' 'one' 'false' 'First'))) @{ link = '<https://api.github.com/orgs/acme/repos?per_page=100&type=public&page=2>; rel="next"' }))
    # GitHub's primary anonymous limit is HTTP 403 with remaining 0 (not retried).
    $script:Plan.Enqueue((Reply 403 '{"message":"slow down"}' @{ 'x-ratelimit-limit' = '60'; 'x-ratelimit-remaining' = '0' }))
    $limited = ''
    try { Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/orgs/acme' -Token '' } catch { $limited = [string]$_.Exception.Message }
    Assert ($limited -match '^RATE_LIMITED\|' -and $limited -match 'do not require a token') "Page 2 rate limit must be explained: $limited"
    NoAuth $script:Seen[1] 'The rate-limited page must still have been anonymous'

    # --- Authenticated path: header sent, private repos kept, token not leaked --
    Reset
    $script:Plan.Enqueue((Reply 200 (Page @(
        (Repo 'acme' 'pub' 'false' 'Public'),
        (Repo 'acme' 'secret' 'true' 'Secret')
    )) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/orgs/acme' -Token $token
    Assert (-not $catalog.anonymous) 'A configured token is not anonymous'
    Assert (@($catalog.repositories | Where-Object { $_.private }).Count -eq 1) 'Private organization repos stay visible with a token'
    Assert ($script:Seen[0].Headers['Authorization'] -eq ('Bearer ' + $token)) 'Authenticated organization list must send the token'
    Assert ($script:Seen[0].Uri -match 'type=all') 'Authenticated organization list asks for every visible repo'
    $asJson = $catalog | ConvertTo-Json -Depth 6
    Assert ($asJson -notmatch [regex]::Escape($token)) 'The catalog must not contain the token'
    $logged = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
    Assert ($logged -notmatch [regex]::Escape($token)) 'The log must not contain the token'

    Reset
    $script:Plan.Enqueue((Reply 200 '{"login":"ada","type":"User"}'))
    $script:Plan.Enqueue((Reply 200 '{"login":"ada"}'))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'ada' 'hidden' 'true' 'Hidden'))) @{ link = '<https://api.github.com/user/repos?per_page=100&type=owner&page=2>; rel="next"' }))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'ada' 'also' 'false' 'Also'))) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/users/ada' -Token $token
    Assert (@($catalog.repositories).Count -eq 2) 'Authenticated profile list keeps every page'
    Assert ($catalog.repositories[0].private) 'The signed-in user profile includes private repos'
    Assert ($script:Seen[2].Uri -match '/user/repos\?') 'The signed-in user is listed from /user/repos'
    EachSeen { param($req) Assert ($req.Headers['Authorization'] -eq ('Bearer ' + $token)) 'Every authenticated profile request sends the token' }

    Reset
    $script:Plan.Enqueue((Reply 200 '{"login":"ada","type":"User"}'))
    $script:Plan.Enqueue((Reply 200 '{"login":"someoneelse"}'))
    $script:Plan.Enqueue((Reply 200 (Page @((Repo 'ada' 'pub' 'false' 'Public'))) @{}))
    $catalog = Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/ada' -Token $token
    Assert ($script:Seen[2].Uri -match '/users/ada/repos\?') 'Another user is not listed from /user/repos'
    Assert ($script:Seen[2].Headers['Authorization'] -eq ('Bearer ' + $token)) 'A token is still sent for another public profile'
    Assert (-not $catalog.repositories[0].private) 'Another profile does not gain private repos'

    Reset
    $script:Plan.Enqueue((Reply 200 '{"login":"ada","type":"User"}'))
    $script:Plan.Enqueue((Reply 401 '{"message":"bad credentials"}'))
    $rejected = ''
    try { Get-GangplankGitHubRepositoryCatalog -Url 'https://github.com/users/ada' -Token $token } catch { $rejected = [string]$_.Exception.Message }
    Assert ($rejected -match '^GIT_AUTH_FAILED\|') "A rejected token must not be ignored: $rejected"
    Assert ($rejected -match 'not ignored') 'The message must say a rejected token is not treated as anonymous'
    Assert ($rejected -notmatch [regex]::Escape($token)) 'The auth failure must not echo the token'
    Assert ($script:Seen.Count -eq 2) 'A rejected token must stop before the repository list'

    # --- Opening and downloading a repository -----------------------------------
    Reset
    $script:Plan.Enqueue((Reply 200 '{"full_name":"acme/demo","private":false,"default_branch":"main"}'))
    $script:Plan.Enqueue((Reply 200 '{"full_name":"acme/demo","private":false,"default_branch":"main"}'))
    $script:Plan.Enqueue((Reply 200 '[{"name":"main"}]'))
    $session = Open-GangplankRepository -Url 'https://github.com/acme/demo' -Token ''
    Assert ($session.ProjectPath -eq 'acme/demo' -and $session.DefaultBranch -eq 'main') 'Anonymous open loads the public repository'
    Assert ([string]::IsNullOrWhiteSpace($session.ProviderObj.Token)) 'Anonymous open keeps an empty token'
    EachSeen { param($req) NoAuth $req 'Anonymous repository open must not send Authorization' }
    $snap = ConvertTo-GangplankSessionSnapshot $session
    Assert (($snap | ConvertTo-Json -Depth 5) -notmatch 'Authorization') 'A session snapshot has no credential header'

    Reset
    $script:Plan.Enqueue((Reply 404 '{"message":"Not Found"}'))
    $missingRepo = ''
    try { Open-GangplankRepository -Url 'https://github.com/acme/private' -Token '' } catch { $missingRepo = [string]$_.Exception.Message }
    Assert ($missingRepo -match '^GIT_REPOSITORY_NOT_FOUND\|') "Anonymous 404: $missingRepo"
    Assert ($missingRepo -match 'without a token' -and $missingRepo -match 'Private') 'Anonymous 404 must explain public vs private'
    NoAuth $script:Seen[0] 'The 404 request must still be anonymous'

    Reset
    $script:Plan.Enqueue((Reply 200 '{"full_name":"acme/demo","private":true,"default_branch":"main"}'))
    $script:Plan.Enqueue((Reply 200 '{"full_name":"acme/demo","private":true,"default_branch":"main"}'))
    $script:Plan.Enqueue((Reply 200 '[{"name":"main"},{"name":"dev"}]'))
    $session = Open-GangplankRepository -Url 'https://github.com/acme/demo' -Token $token
    Assert ($session.Project.private -eq $true) 'A token still opens a private repository'
    Assert (@($session.Branches).Count -eq 2) 'Authenticated open still loads branches'
    EachSeen { param($req) Assert ($req.Headers['Authorization'] -eq ('Bearer ' + $token)) 'Private open sends the token on every request' }
    Assert ((ConvertTo-GangplankSessionSnapshot $session | ConvertTo-Json -Depth 5) -notmatch [regex]::Escape($token)) 'The saved snapshot must not contain the token'

    Reset
    $script:Plan.Enqueue((Reply 401 '{"message":"bad credentials"}'))
    $authFail = ''
    try { Open-GangplankRepository -Url 'https://github.com/acme/demo' -Token $token } catch { $authFail = [string]$_.Exception.Message }
    Assert ($authFail -match '^GIT_AUTH_FAILED\|' -and $authFail -match 'rejected the credential') "Authenticated 401: $authFail"
    Assert ($authFail -notmatch [regex]::Escape($token)) 'Authenticated 401 must not echo the token'

    $env:GANGPLANK_GITLAB_HOST = 'gitlab.example.org'
    $gitlab = ''
    try { Open-GangplankRepository -Url 'https://gitlab.example.org/group/proj' } catch { $gitlab = [string]$_.Exception.Message }
    Assert ($gitlab -match '^CREDENTIAL_MISSING\|') "GitLab without a token must still fail: $gitlab"
    Remove-Item Env:GANGPLANK_GITLAB_HOST -ErrorAction SilentlyContinue

    # Writes still require a token. Reads of the header do not add an empty Bearer.
    Reset
    $anon = [GitHubProvider]::new('https://api.github.com','')
    $blank = [GitHubProvider]::new('https://api.github.com','   ')
    Assert (-not $anon.GetAuthHeaders('GET').ContainsKey('Authorization')) 'Empty token must omit Authorization'
    Assert (-not $blank.GetAuthHeaders('POST').ContainsKey('Authorization')) 'Whitespace token must omit Authorization'
    Assert ($blank.GetAuthHeaders('POST')['Content-Type'] -eq 'application/json') 'Writes still send Content-Type'
    Assert ($anon.GetAuthHeaders('GET')['Authorization'] -eq $null) 'Missing Authorization is not an empty Bearer'
    $with = [GitHubProvider]::new('https://api.github.com',$token)
    Assert ($with.GetAuthHeaders('GET')['Authorization'] -eq ('Bearer ' + $token)) 'A real token is still sent as Bearer'
    $blocked = ''
    $writeSession = [pscustomobject]@{ Provider = 'GitHub'; ProviderObj = $anon; ProjectPath = 'acme/demo'; DefaultBranch = 'main'; Branches = @('main') }
    try { New-GangplankWorkBranch -Session $writeSession -Name 'feature' } catch { $blocked = [string]$_.Exception.Message }
    Assert ($blocked -match '^CREDENTIAL_MISSING\|') "Creating a branch without a token must fail: $blocked"
    Assert ($blocked -match 'do not') 'The write error must say public browsing does not need a token'
    Assert ($script:Seen.Count -eq 0) 'A refused write must not call the API'
    $saveBlocked = ''
    try { Invoke-GangplankWorkspaceSave -Session $writeSession -SelectedPaths @('a.txt') -Message 'nope' } catch { $saveBlocked = [string]$_.Exception.Message }
    Assert ($saveBlocked -match '^CREDENTIAL_MISSING\|') 'Publishing without a token must fail before any upload'
    Assert-GangplankWriteCredential -Session ([pscustomobject]@{ Provider = 'GitHub'; ProviderObj = $with }) -Action 'Publishing'

    $zip = Join-Path $temp 'demo.zip'
    [IO.File]::WriteAllBytes($zip, [byte[]](1,2,3,4))
    Reset
    $script:Plan.Enqueue([pscustomobject]@{ Status = 200; Headers = @{}; Text = ''; File = $zip; NetworkError = '' })
    $anon.DownloadArchive('acme/demo','abc123def456',$zip)
    NoAuth $script:Seen[0] 'Anonymous archive download must not send Authorization'
    Assert ($script:Seen[0].Uri -match '/repos/acme/demo/zipball/') 'Archive download uses the repository zipball'
    Reset
    $script:Plan.Enqueue([pscustomobject]@{ Status = 200; Headers = @{}; Text = ''; File = $zip; NetworkError = '' })
    $with.DownloadArchive('acme/demo','abc123def456',$zip)
    Assert ($script:Seen[0].Headers['Authorization'] -eq ('Bearer ' + $token)) 'Authenticated archive download still sends the token'

    Reset
    $opened = ''
    try { Open-GangplankRepository -Url 'https://github.com/orgs/acme' -Token '' } catch { $opened = [string]$_.Exception.Message }
    Assert ($opened -match '^BAD_REQUEST\|') 'Opening an organization URL directly must ask for a repository choice'
    Assert ($script:Seen.Count -eq 0) 'That refusal must not call GitHub'

    $script:GangplankHttpTransport = $null
    $script:GangplankHttpSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
} finally {
    foreach ($n in @($saved.Keys)) {
        if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$n" $saved[$n] }
    }
}
Write-Host 'Public repository checks passed.' -ForegroundColor Green
