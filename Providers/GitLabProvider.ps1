#Requires -Version 5.1
# ============================================================
#  Providers/GitLabProvider.ps1
#  GitLab REST: archive pull, commits push, merge requests
# ============================================================

class GitLabProvider : GitProviderBase {
    GitLabProvider([string]$baseUrl, [string]$token) : base("GitLab", $baseUrl, $token) {
        $this.ApiRoot = "$($this.BaseUrl)/api/v4"
    }

    [hashtable] GetAuthHeaders([string]$method) {
        $h = @{ "PRIVATE-TOKEN" = $this.Token }
        if ($method -in @("POST", "PUT", "PATCH")) {
            $h["Content-Type"] = "application/json"
        }
        return $h
    }

    [string] EncodePath([string]$path) {
        return ($path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '%2F'
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body, [string]$outFile) {
        $uri = "$($this.ApiRoot)/$($endpoint.TrimStart('/'))"
        Write-GangplankLog -Level DEBUG -Message "GitLab $method $(Get-GangplankSafeUrl $uri)"
        if (-not [string]::IsNullOrWhiteSpace($outFile)) {
            [void](Invoke-GangplankDownload -Provider 'GitLab' -Uri $uri -AuthHeaders $this.GetAuthHeaders('GET') -OutFile $outFile)
            return $true
        }
        $payload = $null
        if ($null -ne $body) {
            $payload = if ($body -is [string]) { $body } else { ($body | ConvertTo-Json -Depth 12 -Compress) }
        }
        $response = Invoke-GangplankHttpRequest -Method $method -Uri $uri -Headers $this.GetAuthHeaders($method) -Body $payload
        $endpointPath = ($endpoint.TrimStart('/') -split '\?')[0]
        return (ConvertFrom-GangplankApiResponse -Provider 'GitLab' -Method $method -Endpoint $endpointPath -Response $response)
    }

    [object] InvokeApi([string]$method, [string]$endpoint) {
        return $this.InvokeApi($method, $endpoint, $null, $null)
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body) {
        return $this.InvokeApi($method, $endpoint, $body, $null)
    }

    [object] ResolveProject([string]$projectPath) {
        $enc = $this.EncodePath($projectPath)
        return $this.InvokeApi("GET", "projects/$enc")
    }

    [string] GetDefaultBranch([string]$projectPath) {
        try {
            $p = $this.ResolveProject($projectPath)
            if ($p.default_branch) { return [string]$p.default_branch }
        } catch {
            Write-GangplankLog -Level WARN -Message "GetDefaultBranch: $($_.Exception.Message)"
        }
        return "main"
    }

    [string[]] GetBranches([string]$projectPath) {
        $all = @()
        $enc = $this.EncodePath($projectPath)
        $page = 1
        # Errors propagate: a silently partial branch list looks like real data.
        do {
            $batch = $this.InvokeApi("GET", "projects/$enc/repository/branches?per_page=100&page=$page")
            if (-not $batch) { break }
            $all += @($batch | ForEach-Object { $_.name })
            $page++
        } while (@($batch).Count -eq 100 -and $page -le 50)
        return $all
    }

    [hashtable] GetFileText([string]$projectPath, [string]$ref, [string]$path, [int]$maxBytes) {
        # One file at a commit (the diff viewer's "before"), through the repository files API.
        # @{ Found; Size; TooLarge; Binary; Text }; a file that is not there is Found = $false.
        $enc = $this.EncodePath($projectPath)
        try {
            $item = $this.InvokeApi('GET', "projects/$enc/repository/files/" + $this.EncodePath($path) + '?ref=' + [uri]::EscapeDataString($ref))
        } catch {
            if ([string]$_.Exception.Message -match '^NOT_FOUND\|') { return @{ Found = $false } }
            throw
        }
        return (ConvertFrom-GangplankFileContent -Item $item -MaxBytes $maxBytes)
    }

    [void] DownloadArchive([string]$projectPath, [string]$ref, [string]$outZip) {
        $enc = $this.EncodePath($projectPath)
        $refEnc = [uri]::EscapeDataString($ref)
        $this.InvokeApi("GET", "projects/$enc/repository/archive.zip?sha=$refEnc", $null, $outZip)
    }

    [hashtable] TryGetRemoteFileMap([string]$projectPath, [string]$branch) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ks-gl-{0}.zip" -f [guid]::NewGuid().ToString("N"))
        try {
            $this.DownloadArchive($projectPath, $branch, $tmp)
            if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -eq 0)) {
                return @{}
            }
            return (Get-GangplankRemoteMapFromZip -ZipPath $tmp)
        } catch {
            Write-GangplankLog -Level INFO -Message "Remote map unavailable (empty branch?): $($_.Exception.Message)"
            return @{}
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    [object] CreateCommit([string]$projectPath, [string]$branch, [string]$message, [object[]]$actions) {
        $enc = $this.EncodePath($projectPath)
        $msgJson = ($message | ConvertTo-Json)
        $actionsJson = ($actions | ConvertTo-Json -Depth 8 -Compress)
        if (@($actions).Count -eq 1 -and $actionsJson -notmatch '^\s*\[') {
            $actionsJson = "[$actionsJson]"
        }
        $json = "{`"branch`":`"$branch`",`"commit_message`":$msgJson,`"actions`":$actionsJson}"
        return $this.InvokeApi("POST", "projects/$enc/repository/commits", $json)
    }

    [object] PushFolder([string]$projectPath, [string]$branch, [string]$localPath, [string]$message, [string]$deletePolicy) {
        if (-not $deletePolicy) { $deletePolicy = "Omit" }
        $localMap = Get-GangplankLocalFileMap -Root $localPath
        if ($localMap.Count -eq 0) {
            throw "No files to push under $localPath"
        }
        $remoteMap = $this.TryGetRemoteFileMap($projectPath, $branch)
        $diff = Get-GangplankPathDiff -LocalMap $localMap -RemoteMap $remoteMap
        Write-GangplankLog -Level INFO -Message ("Diff new={0} mod={1} del={2}" -f @($diff.New).Count, @($diff.Modified).Count, @($diff.Deleted).Count)

        $actions = New-GangplankPushActions -LocalPath $localPath -Diff $diff -DeletePolicy $deletePolicy
        if (@($actions).Count -eq 0) {
            return [PSCustomObject]@{
                Branch    = $branch
                FileCount = 0
                Commits   = @()
                Message   = "Nothing to push - local matches remote"
                Diff      = $diff
                Url       = "$($this.BaseUrl)/$projectPath/-/tree/$branch"
            }
        }

        $batches = Split-GangplankPushBatches -Actions $actions -Branch $branch -Message $message
        $commits = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($batch in $batches) {
            $i++
            $msg = if ($batches.Count -eq 1) { $message } else { "$message ($i/$($batches.Count))" }
            Write-GangplankLog -Level INFO -Message ("Commit batch {0}/{1} actions={2}" -f $i, $batches.Count, @($batch).Count)
            $result = $this.CreateCommit($projectPath, $branch, $msg, @($batch))
            if ($result.short_id) { [void]$commits.Add([string]$result.short_id) }
            elseif ($result.id) { [void]$commits.Add([string]$result.id) }
        }

        $first = if ($commits.Count -gt 0) { $commits[0] } else { $null }
        return [PSCustomObject]@{
            Branch    = $branch
            CommitSha = $first
            Commits   = @($commits)
            FileCount = @($actions).Count
            Diff      = $diff
            Message   = $null
            Url       = "$($this.BaseUrl)/$projectPath/-/tree/$branch"
        }
    }

    [object] CreateMergeRequest([string]$projectPath, [string]$source, [string]$target, [string]$title, [string]$description) {
        $enc = $this.EncodePath($projectPath)
        $body = @{
            source_branch = $source
            target_branch = $target
            title         = $title
            description   = $description
        }
        return $this.InvokeApi("POST", "projects/$enc/merge_requests", $body)
    }
}
