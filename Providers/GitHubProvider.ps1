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
        $h = @{
            "Authorization"        = "Bearer $($this.Token)"
            "Accept"               = "application/vnd.github+json"
            "User-Agent"           = "Gangplank"
            "X-GitHub-Api-Version" = "2022-11-28"
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
