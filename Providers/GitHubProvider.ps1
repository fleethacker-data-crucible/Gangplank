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
            "User-Agent"           = "Keystone"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        if ($method -in @("POST", "PUT", "PATCH")) {
            $h["Content-Type"] = "application/json"
        }
        return $h
    }

    [void] EnsureTls() {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body, [string]$outFile) {
        $this.EnsureTls()
        $uri = "$($this.ApiRoot)/$($endpoint.TrimStart('/'))"
        $headers = $this.GetAuthHeaders($method)
        Write-KeystoneLog -Level DEBUG -Message "GitHub $method $uri"

        $params = @{
            Uri             = $uri
            Method          = $method
            Headers         = $headers
            UseBasicParsing = $true
            ErrorAction     = "Stop"
        }
        if (-not [string]::IsNullOrWhiteSpace($outFile)) {
            $params["OutFile"] = $outFile
            try {
                Invoke-WebRequest @params | Out-Null
                return $true
            }
            catch {
                throw $this.FormatApiError($method, $endpoint, $uri, $_)
            }
        }
        if ($null -ne $body) {
            if ($body -is [string]) {
                $params["Body"] = $body
            }
            else {
                $params["Body"] = ($body | ConvertTo-Json -Depth 20 -Compress)
            }
        }
        try {
            return (Invoke-RestMethod @params)
        }
        catch {
            throw $this.FormatApiError($method, $endpoint, $uri, $_)
        }
    }

    [string] FormatApiError([string]$method, [string]$endpoint, [string]$uri, $err) {
        $status = $null
        $detail = $err.Exception.Message
        try {
            $resp = $err.Exception.Response
            if ($resp) {
                $status = [int]$resp.StatusCode
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $bodyText = $reader.ReadToEnd()
                    $reader.Close()
                    if ($bodyText) { $detail = "$detail | $bodyText" }
                }
            }
        } catch { }
        Write-KeystoneLog -Level ERROR -Message ("GitHub API fail {0} {1} status={2} {3}" -f $method, $uri, $status, $detail)
        return ("GitHub API {0} {1} failed (HTTP {2}): {3}" -f $method, $endpoint, $status, $detail)
    }

    [object] InvokeApi([string]$method, [string]$endpoint) {
        return $this.InvokeApi($method, $endpoint, $null, $null)
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body) {
        return $this.InvokeApi($method, $endpoint, $body, $null)
    }

    [void] DownloadArchive([string]$projectPath, [string]$ref, [string]$outZip) {
        $this.EnsureTls()
        $refEnc = [uri]::EscapeDataString($ref)
        $uri = "$($this.ApiRoot)/repos/$projectPath/zipball/$refEnc"
        Write-KeystoneLog -Level INFO -Message "GitHub zipball $uri"
        $headers = $this.GetAuthHeaders("GET")
        try {
            Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $outZip `
                -UseBasicParsing -MaximumRedirection 8 -ErrorAction Stop | Out-Null
            if ((Test-Path -LiteralPath $outZip) -and ((Get-Item -LiteralPath $outZip).Length -gt 0)) {
                return
            }
        }
        catch {
            throw ("GitHub archive download failed for {0} @ '{1}'. Empty repos return 404 until first commit. API: {2}" -f $projectPath, $ref, $_.Exception.Message)
        }
        throw ("GitHub archive download failed for {0} @ '{1}'" -f $projectPath, $ref)
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
        $all = @()
        $page = 1
        do {
            try {
                $batch = $this.InvokeApi("GET", "repos/$projectPath/branches?per_page=100&page=$page")
            }
            catch {
                break
            }
            if (-not $batch) { break }
            $all += @($batch | ForEach-Object { $_.name })
            $page++
        } while (@($batch).Count -eq 100)
        return $all
    }

    [string] GetRefSha([string]$projectPath, [string]$branch) {
        try {
            $ref = $this.InvokeApi("GET", "repos/$projectPath/git/ref/heads/$branch")
            if ($ref -and $ref.object -and $ref.object.sha) {
                return [string]$ref.object.sha
            }
        }
        catch {
            Write-KeystoneLog -Level DEBUG -Message "GetRefSha($branch): $($_.Exception.Message)"
        }
        return $null
    }

    [bool] IsEmptyRepo([string]$projectPath) {
        $sha = $this.GetRefSha($projectPath, "main")
        if ($sha) { return $false }
        $sha = $this.GetRefSha($projectPath, "master")
        if ($sha) { return $false }
        $branches = @($this.GetBranches($projectPath))
        return ($branches.Count -eq 0)
    }

    # Initialize empty repo with one file via Contents API so Git Data API works
    [string] InitializeWithContentsApi([string]$projectPath, [string]$branch, [string]$relativePath, [byte[]]$bytes, [string]$message) {
        $pathEnc = ($relativePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $body = @{
            message = $message
            content = [Convert]::ToBase64String($bytes)
            branch  = $branch
        }
        Write-KeystoneLog -Level INFO -Message "Contents API init: $relativePath on $branch"
        $r = $this.InvokeApi("PUT", "repos/$projectPath/contents/$pathEnc", $body)
        if ($r.commit -and $r.commit.sha) {
            return [string]$r.commit.sha
        }
        return $null
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
        Write-KeystoneLog -Level INFO -Message ("Ref heads/{0} existing={1} new={2}" -f $branch, $existing, $commitSha)

        $body = @{
            sha   = $commitSha
            force = $true
        }
        if ($existing) {
            $this.InvokeApi("PATCH", "repos/$projectPath/git/refs/heads/$branch", $body) | Out-Null
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
            Write-KeystoneLog -Level WARN -Message "POST ref failed - trying PATCH force: $($_.Exception.Message)"
            $this.InvokeApi("PATCH", "repos/$projectPath/git/refs/heads/$branch", $body) | Out-Null
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

    [bool] ShouldExcludePath([string]$relDir, [hashtable]$excludeSet) {
        if ([string]::IsNullOrWhiteSpace($relDir)) { return $false }
        foreach ($p in ($relDir -split '/')) {
            if ($p -and $excludeSet.ContainsKey($p.ToLowerInvariant())) {
                return $true
            }
        }
        return $false
    }

    [object] PushFolder([string]$projectPath, [string]$branch, [string]$localPath, [string]$message, [string[]]$excludeDirNames) {
        if (-not (Test-Path -LiteralPath $localPath)) {
            throw "Local path not found: $localPath"
        }
        if (-not $excludeDirNames -or $excludeDirNames.Count -eq 0) {
            $excludeDirNames = @("Logs", "work", ".git", ".vs", "node_modules")
        }
        $excludeSet = @{}
        foreach ($d in $excludeDirNames) {
            $excludeSet[$d.ToLowerInvariant()] = $true
        }

        Write-KeystoneLog -Level INFO -Message "Scanning $localPath for push"
        $fileList = New-Object System.Collections.Generic.List[object]
        foreach ($f in @(Get-ChildItem -LiteralPath $localPath -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $relDir = $f.DirectoryName.Substring($localPath.Length).TrimStart('\', '/').Replace('\', '/')
            if ($this.ShouldExcludePath($relDir, $excludeSet)) { continue }
            [void]$fileList.Add($f)
        }
        if ($fileList.Count -eq 0) {
            throw "No files to push under $localPath (after excludes)"
        }
        Write-KeystoneLog -Level INFO -Message ("Files to push: {0}" -f $fileList.Count)

        # Empty repo: Git Data API blobs return 409 - seed with Contents API first
        $parentSha = $this.GetRefSha($projectPath, $branch)
        if (-not $parentSha) {
            Write-KeystoneLog -Level INFO -Message "No ref for '$branch' - treating as empty / uninitialized"
            $seed = $fileList[0]
            $seedRel = $seed.FullName.Substring($localPath.Length).TrimStart('\', '/').Replace('\', '/')
            $seedBytes = [IO.File]::ReadAllBytes($seed.FullName)
            $initMsg = "Initialize repository (Keystone)"
            try {
                $null = $this.InitializeWithContentsApi($projectPath, $branch, $seedRel, $seedBytes, $initMsg)
            }
            catch {
                throw ("Failed to initialize empty GitHub repo via Contents API: {0}. Token needs Contents: Read and write." -f $_.Exception.Message)
            }
            $parentSha = $this.GetRefSha($projectPath, $branch)
            if (-not $parentSha) {
                # branch name might differ after init
                Start-Sleep -Seconds 1
                $parentSha = $this.GetRefSha($projectPath, $branch)
            }
            if (-not $parentSha) {
                throw "Repo still has no branch ref after Contents API init. Check default branch name on GitHub."
            }
            Write-KeystoneLog -Level INFO -Message "Initialized empty repo; parent=$parentSha"
        }

        $baseTree = $null
        try {
            $commitObj = $this.InvokeApi("GET", "repos/$projectPath/git/commits/$parentSha")
            if ($commitObj.tree -and $commitObj.tree.sha) {
                $baseTree = [string]$commitObj.tree.sha
            }
        } catch { }

        $treeItems = New-Object System.Collections.Generic.List[object]
        $n = 0
        foreach ($f in $fileList) {
            $n++
            $rel = $f.FullName.Substring($localPath.Length).TrimStart('\', '/').Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $sha = $this.CreateBlob($projectPath, $bytes)
            [void]$treeItems.Add(@{
                path = $rel
                mode = "100644"
                type = "blob"
                sha  = $sha
            })
            if (($n % 10) -eq 0 -or $n -eq $fileList.Count) {
                Write-KeystoneLog -Level INFO -Message ("Blobbed {0}/{1}: {2}" -f $n, $fileList.Count, $rel)
            }
        }

        $treeSha = $this.CreateTree($projectPath, $treeItems.ToArray(), $baseTree)
        Write-KeystoneLog -Level INFO -Message "Tree $treeSha"

        $commitSha = $this.CreateCommit($projectPath, $message, $treeSha, @($parentSha))
        Write-KeystoneLog -Level INFO -Message "Commit $commitSha"

        $this.CreateOrUpdateBranchRef($projectPath, $branch, $commitSha, $true)
        Write-KeystoneLog -Level INFO -Message "Branch $branch -> $commitSha"

        return [PSCustomObject]@{
            Branch    = $branch
            CommitSha = $commitSha
            Commits   = @($commitSha)
            TreeSha   = $treeSha
            FileCount = $fileList.Count
            ParentSha = $parentSha
            Message   = $null
            Url       = "https://github.com/$projectPath/tree/$branch"
        }
    }
}
