#Requires -Version 5.1
# ============================================================
#  Providers/GitHubProvider.ps1
#  Git Data API + Contents API fallback for empty repos
# ============================================================

class GitHubProvider : GitProviderBase {
    GitHubProvider([string]$baseUrl, [string]$token) : base("GitHub", $baseUrl, $token) {
        if ($baseUrl -match 'github\.com' -and $baseUrl -notmatch 'api\.github\.com') {
            $this.ApiRoot = "https://api.github.com"
        }
        else {
            $this.ApiRoot = $baseUrl.TrimEnd('/')
            if ($this.ApiRoot -eq "https://github.com") {
                $this.ApiRoot = "https://api.github.com"
            }
        }
    }

    [hashtable] GetAuthHeaders([string]$method) {
        # No Authorization header at all when there is no token. An empty
        # "Bearer" value makes GitHub reject public requests as bad credentials.
        $h = @{
            "Accept"               = "application/vnd.github+json"
            "User-Agent"           = "Gangplank"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        if (-not [string]::IsNullOrWhiteSpace($this.Token)) {
            $h["Authorization"] = "Bearer $($this.Token)"
        }
        if ($method -in @("POST", "PUT", "PATCH")) {
            $h["Content-Type"] = "application/json"
        }
        return $h
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body, [string]$outFile) {
        $uri = "$($this.ApiRoot)/$($endpoint.TrimStart('/'))"
        Write-GangplankLog -Level DEBUG -Message "GitHub $method $(Get-GangplankSafeUrl $uri)"
        if (-not [string]::IsNullOrWhiteSpace($outFile)) {
            [void](Invoke-GangplankDownload -Provider 'GitHub' -Uri $uri -AuthHeaders $this.GetAuthHeaders('GET') -OutFile $outFile)
            return $true
        }
        $payload = $null
        if ($null -ne $body) {
            $payload = if ($body -is [string]) { $body } else { ($body | ConvertTo-Json -Depth 20 -Compress) }
        }
        $response = Invoke-GangplankHttpRequest -Method $method -Uri $uri -Headers $this.GetAuthHeaders($method) -Body $payload
        $endpointPath = ($endpoint.TrimStart('/') -split '\?')[0]
        return (ConvertFrom-GangplankApiResponse -Provider 'GitHub' -Method $method -Endpoint $endpointPath -Response $response)
    }

    [object] InvokeApi([string]$method, [string]$endpoint) {
        return $this.InvokeApi($method, $endpoint, $null, $null)
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body) {
        return $this.InvokeApi($method, $endpoint, $body, $null)
    }

    [void] DownloadArchive([string]$projectPath, [string]$ref, [string]$outZip) {
        # api.github.com answers with a redirect to codeload.github.com; the token
        # is sent to the API host only (Invoke-GangplankDownload).
        $refEnc = [uri]::EscapeDataString($ref)
        $uri = "$($this.ApiRoot)/repos/$projectPath/zipball/$refEnc"
        Write-GangplankLog -Level INFO -Message "GitHub zipball $(Get-GangplankSafeUrl $uri)"
        [void](Invoke-GangplankDownload -Provider 'GitHub' -Uri $uri -AuthHeaders $this.GetAuthHeaders('GET') -OutFile $outZip)
        if (-not (Test-Path -LiteralPath $outZip) -or (Get-Item -LiteralPath $outZip).Length -eq 0) {
            throw ("NOT_FOUND|GitHub archive for {0} @ '{1}' was empty. Empty repositories have no archive until the first commit." -f $projectPath, $ref)
        }
    }

    [object] ResolveProject([string]$projectPath) {
        return $this.InvokeApi("GET", "repos/$projectPath")
    }

    [string] GetDefaultBranch([string]$projectPath) {
        try {
            $p = $this.ResolveProject($projectPath)
            if ($p.default_branch) { return [string]$p.default_branch }
        } catch { }
        return "main"
    }

    [string[]] GetBranches([string]$projectPath) {
        # Errors propagate: a silently partial branch list looks like real data.
        $uri = "$($this.ApiRoot)/repos/$projectPath/branches?per_page=100"
        $batch = Invoke-GangplankPagedGet -Provider 'GitHub' -Uri $uri -Headers $this.GetAuthHeaders('GET')
        return @($batch | ForEach-Object { $_.name })
    }

    [string] GetRefSha([string]$projectPath, [string]$branch) {
        # $null means the branch does not exist (404). Any other failure (401, 403,
        # network) is thrown, so callers do not mistake it for "the branch moved".
        $refPath = ConvertTo-GangplankRefPath -Ref $branch
        try {
            $ref = $this.InvokeApi("GET", "repos/$projectPath/git/ref/heads/$refPath")
        }
        catch {
            # 404: no such branch. 409: GitHub's answer for a repository with no commits yet.
            if ([string]$_.Exception.Message -match '^(NOT_FOUND|CONFLICT)\|') {
                Write-GangplankLog -Level DEBUG -Message "GetRefSha($branch): branch not found"
                return $null
            }
            throw
        }
        if ($ref -and $ref.object -and $ref.object.sha) {
            return [string]$ref.object.sha
        }
        return $null
    }

    [hashtable] GetFileText([string]$projectPath, [string]$ref, [string]$path, [int]$maxBytes) {
        # One file at a commit (the diff viewer's "before"), through the Contents API.
        # @{ Found; Size; TooLarge; Binary; Text }; a file that is not there is Found = $false.
        $encPath = ($path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        try {
            $item = $this.InvokeApi('GET', "repos/$projectPath/contents/$encPath" + '?ref=' + [uri]::EscapeDataString($ref))
        } catch {
            if ([string]$_.Exception.Message -match '^NOT_FOUND\|') { return @{ Found = $false } }
            throw
        }
        return (ConvertFrom-GangplankFileContent -Item $item -MaxBytes $maxBytes)
    }

    [hashtable] GetPathModes([string]$projectPath, [string]$treeSha, [string[]]$paths) {
        # Existing Git file modes (100644, 100755, 120000...) for the given paths,
        # walking only the directories that contain them. Paths not in the tree
        # are absent from the result.
        $modes = @{}
        $trees = @{ '' = $treeSha }
        $listed = @{}
        foreach ($p in @($paths | Sort-Object -Unique)) {
            $parts = @($p -split '/')
            $dir = ''
            $ok = $true
            for ($i = 0; $i -lt $parts.Count; $i++) {
                if (-not $listed.ContainsKey($dir)) {
                    if (-not $trees.ContainsKey($dir)) { $ok = $false; break }
                    $listing = $this.InvokeApi('GET', "repos/$projectPath/git/trees/$($trees[$dir])")
                    $entries = @{}
                    foreach ($e in @($listing.tree)) {
                        $child = if ($dir) { "$dir/$($e.path)" } else { [string]$e.path }
                        $entries[$child] = $e
                        if ($e.type -eq 'tree') { $trees[$child] = [string]$e.sha }
                    }
                    $listed[$dir] = $entries
                }
                $next = if ($dir) { "$dir/$($parts[$i])" } else { $parts[$i] }
                if ($i -eq $parts.Count - 1) {
                    $entry = $listed[$dir][$next]
                    if ($entry -and $entry.type -eq 'blob') { $modes[$p] = [string]$entry.mode }
                } else {
                    $dir = $next
                }
            }
        }
        return $modes
    }

    [string] CreateBlob([string]$projectPath, [byte[]]$bytes) {
        $body = @{
            content  = [Convert]::ToBase64String($bytes)
            encoding = "base64"
        }
        $r = $this.InvokeApi("POST", "repos/$projectPath/git/blobs", $body)
        return [string]$r.sha
    }

    [string] CreateTree([string]$projectPath, [object[]]$treeItems, [string]$baseTreeSha) {
        $itemsJson = ($treeItems | ConvertTo-Json -Depth 8 -Compress)
        if (@($treeItems).Count -eq 1 -and $itemsJson -notmatch '^\s*\[') {
            $itemsJson = "[$itemsJson]"
        }
        if ($baseTreeSha) {
            $json = "{`"base_tree`":`"$baseTreeSha`",`"tree`":$itemsJson}"
        }
        else {
            $json = "{`"tree`":$itemsJson}"
        }
        $r = $this.InvokeApi("POST", "repos/$projectPath/git/trees", $json)
        return [string]$r.sha
    }

    [string] CreateCommit([string]$projectPath, [string]$message, [string]$treeSha, [string[]]$parentShas) {
        $msgJson = ($message | ConvertTo-Json)
        if ($parentShas -and $parentShas.Count -gt 0) {
            $parentsJson = ($parentShas | ConvertTo-Json -Compress)
            if ($parentShas.Count -eq 1 -and $parentsJson -notmatch '^\s*\[') {
                $parentsJson = "[$parentsJson]"
            }
        }
        else {
            $parentsJson = "[]"
        }
        $json = "{`"message`":$msgJson,`"tree`":`"$treeSha`",`"parents`":$parentsJson}"
        $r = $this.InvokeApi("POST", "repos/$projectPath/git/commits", $json)
        return [string]$r.sha
    }

    [void] CreateOrUpdateBranchRef([string]$projectPath, [string]$branch, [string]$commitSha, [bool]$force) {
        $existing = $this.GetRefSha($projectPath, $branch)
        Write-GangplankLog -Level INFO -Message ("Ref heads/{0} existing={1} new={2}" -f $branch, $existing, $commitSha)

        # Never forced: a branch that moved since our parent commit is rejected
        # as a non-fast-forward. The $force parameter is kept for API stability.
        $body = @{
            sha   = $commitSha
            force = $false
        }
        $refPath = ConvertTo-GangplankRefPath -Ref $branch
        if ($existing) {
            $this.InvokeApi("PATCH", "repos/$projectPath/git/refs/heads/$refPath", $body) | Out-Null
            return
        }
        try {
            $create = @{
                ref = "refs/heads/$branch"
                sha = $commitSha
            }
            $this.InvokeApi("POST", "repos/$projectPath/git/refs", $create) | Out-Null
        }
        catch {
            # Only "already exists" (created meanwhile) falls back to a non-forced update;
            # any other failure (invalid name, permissions) is reported as it is.
            if ([string]$_.Exception.Message -notmatch '^CONFLICT\|') { throw }
            Write-GangplankLog -Level WARN -Message "Branch $branch appeared while saving; updating it without force."
            $this.InvokeApi("PATCH", "repos/$projectPath/git/refs/heads/$refPath", $body) | Out-Null
        }
    }

    [object] CreatePullRequest([string]$projectPath, [string]$head, [string]$base, [string]$title, [string]$bodyText) {
        $payload = @{
            title = $title
            head  = $head
            base  = $base
            body  = $bodyText
        }
        return $this.InvokeApi("POST", "repos/$projectPath/pulls", $payload)
    }
}

function ConvertTo-GangplankPublicRepoRow {
    # A browser-safe repository row. The URL is built here; the API html_url is not trusted.
    param($Item,[string]$Owner)
    $full = [string]$Item.full_name
    $prefix = $Owner + '/'
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $null }
    $repoName = $full.Substring($prefix.Length)
    if ($repoName -notmatch '^[A-Za-z0-9_.-]{1,100}$' -or $repoName -eq '.' -or $repoName -eq '..') { return $null }
    $desc = [string]$Item.description
    $desc = $desc -replace '[\r\n\x00-\x1F]+',' '
    $desc = $desc.Trim()
    if ($desc.Length -gt 180) { $desc = $desc.Substring(0,180) + '...' }
    return [ordered]@{
        name        = $repoName
        fullName    = $full
        private     = [bool]$Item.private
        description = $desc
        url         = ('https://github.com/' + $full)
    }
}

function Resolve-GangplankGitHubAccount {
    # @{ Kind; Name } from GET /users/{name}. Organizations answer here too.
    param($Provider,[string]$Name,[string]$ExplicitMode)
    $info = $null
    try {
        $info = $Provider.InvokeApi('GET', ('users/' + [uri]::EscapeDataString($Name)))
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '^RATE_LIMITED\|') { throw }
        if ($msg -match '^NOT_FOUND\|') {
            $what = if ($ExplicitMode -eq 'user') { 'user profile' } else { 'GitHub account' }
            throw ("NOT_FOUND|No public {0} named '{1}' was found. Public lists do not require a token. If the account is private, add an optional token in Settings." -f $what, $Name)
        }
        throw
    }
    $canonical = $Name
    if ($info.login) {
        $candidate = [string]$info.login
        if ($candidate -match '^[A-Za-z0-9]([A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$') { $canonical = $candidate }
    }
    $type = [string]$info.type
    $kind = ''
    if ($type -eq 'Organization') { $kind = 'organization' }
    elseif ($type -eq 'User') { $kind = 'user' }
    else { throw "NOT_FOUND|GitHub did not recognize '$Name' as a user or an organization." }
    return @{ Kind = $kind; Name = $canonical }
}

function Get-GangplankGitHubRepositoryCatalog {
    # Public organization or user repositories. With no token the request is
    # anonymous (public only). A configured token is sent and private repositories
    # that token can see are included. The token is never returned or logged.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token
    )
    $target = Resolve-GangplankConnectTarget -Url $Url
    if ($target.Provider -ne 'GitHub' -or $target.Mode -eq 'repository') {
        throw 'BAD_REQUEST|Enter a GitHub organization or user profile to list repositories.'
    }
    if (-not $PSBoundParameters.ContainsKey('Token')) {
        $hostName = ''
        try { $hostName = ([uri][string]$target.BaseUrl).Host } catch { }
        $Token = Get-GangplankOptionalProviderToken -Provider 'GitHub' -TargetHost $hostName
    }
    $base = if ([string]$target.BaseUrl -match 'github\.com') { 'https://api.github.com' } else { [string]$target.BaseUrl }
    $prov = New-GangplankProvider -Provider 'GitHub' -BaseUrl $base -Token $Token
    $anonymous = [string]::IsNullOrWhiteSpace($prov.Token)
    $kind = [string]$target.Mode
    $name = [string]$target.Owner
    if ($kind -eq 'owner' -or $kind -eq 'user') {
        $account = Resolve-GangplankGitHubAccount -Provider $prov -Name $name -ExplicitMode $kind
        $kind = [string]$account.Kind
        $name = [string]$account.Name
    }
    $escaped = [uri]::EscapeDataString($name)
    $listPath = ''
    if ($kind -eq 'organization') {
        $repoType = if ($anonymous) { 'public' } else { 'all' }
        $listPath = "orgs/$escaped/repos?per_page=100&type=$repoType"
    } else {
        $listPath = "users/$escaped/repos?per_page=100&type=owner"
        if (-not $anonymous) {
            $me = $null
            try { $me = $prov.InvokeApi('GET','user') } catch {
                $msg = [string]$_.Exception.Message
                if ($msg -match '^RATE_LIMITED\|') { throw }
                if ($msg -match '^AUTH_REJECTED\|') {
                    throw 'GIT_AUTH_FAILED|GitHub rejected the configured token. Public browsing does not require a token, but a rejected token is not ignored. Check it in Settings.'
                }
                throw
            }
            if ($me.login -and [string]::Equals([string]$me.login, $name, [StringComparison]::OrdinalIgnoreCase)) {
                $listPath = 'user/repos?per_page=100&type=owner'
            }
        }
    }
    $uri = ($prov.ApiRoot.TrimEnd('/') + '/' + $listPath)
    $items = @()
    try {
        $items = @(Invoke-GangplankPagedGet -Provider 'GitHub' -Uri $uri -Headers $prov.GetAuthHeaders('GET'))
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '^RATE_LIMITED\|') { throw }
        if ($anonymous -and $msg -match '^AUTH_REJECTED\|') {
            throw 'GIT_AUTH_FAILED|GitHub refused the anonymous request. Public repositories do not require a token. If this account is private, add an optional token in Settings.'
        }
        if ($anonymous -and $msg -match '^FORBIDDEN\|') {
            throw 'GIT_PERMISSION_DENIED|GitHub denied anonymous access. Public repositories do not require a token. Add an optional token in Settings for private access or a higher limit.'
        }
        if (-not $anonymous -and $msg -match '^AUTH_REJECTED\|') {
            throw 'GIT_AUTH_FAILED|GitHub rejected the configured token. Public browsing does not require a token, but a rejected token is not ignored. Check it in Settings.'
        }
        if ($msg -match '^NOT_FOUND\|') {
            $label = if ($kind -eq 'organization') { 'organization' } else { 'user profile' }
            throw ("NOT_FOUND|No public {0} named '{1}' was found. Public lists do not require a token. If it is private, add an optional token in Settings." -f $label, $name)
        }
        throw
    }
    $repos = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($items)) {
        $row = ConvertTo-GangplankPublicRepoRow -Item $item -Owner $name
        if ($row) { [void]$repos.Add($row) }
    }
    # A real object array, so a single repository is not unwrapped into one row.
    $rows = New-Object object[] $repos.Count
    for ($i = 0; $i -lt $repos.Count; $i++) { $rows[$i] = $repos[$i] }
    Write-GangplankLog -Level INFO -Message ("GitHub repository list for {0} ({1}), anonymous={2}, count={3}" -f $name, $kind, $anonymous, $rows.Length)
    return [pscustomobject]@{
        kind           = $kind
        name           = $name
        anonymous      = [bool]$anonymous
        repositories   = $rows
    }
}
