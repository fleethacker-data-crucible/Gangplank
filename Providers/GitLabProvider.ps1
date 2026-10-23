#Requires -Version 5.1
# ============================================================
#  Providers/GitLabProvider.ps1
#  GitLab REST: archive pull, commits push, merge requests
# ============================================================

class GitLabProvider : GitProviderBase {
    GitLabProvider([string]$baseUrl, [string]$token) : base("GitLab", $baseUrl, $token) {
        $this.ApiRoot = "$($this.BaseUrl)/api/v4"
    }

    [void] EnsureTls() {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
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
        $this.EnsureTls()
        $uri = "$($this.ApiRoot)/$($endpoint.TrimStart('/'))"
        $headers = $this.GetAuthHeaders($method)
        Write-KeystoneLog -Level DEBUG -Message "GitLab $method $uri"

        $params = @{
            Uri             = $uri
            Method          = $method
            Headers         = $headers
            UseBasicParsing = $true
            ErrorAction     = "Stop"
        }
        if (-not [string]::IsNullOrWhiteSpace($outFile)) {
            $params["OutFile"] = $outFile
            Invoke-WebRequest @params | Out-Null
            return $true
        }
        if ($null -ne $body) {
            if ($body -is [string]) {
                $params["Body"] = $body
            }
            else {
                $params["Body"] = ($body | ConvertTo-Json -Depth 12 -Compress)
            }
        }
        return (Invoke-RestMethod @params)
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
            Write-KeystoneLog -Level WARN -Message "GetDefaultBranch: $($_.Exception.Message)"
        }
        return "main"
    }

    [string[]] GetBranches([string]$projectPath) {
        $all = @()
        $enc = $this.EncodePath($projectPath)
        $page = 1
        try {
            do {
                $batch = $this.InvokeApi("GET", "projects/$enc/repository/branches?per_page=100&page=$page")
                if (-not $batch) { break }
                $all += @($batch | ForEach-Object { $_.name })
                $page++
            } while (@($batch).Count -eq 100)
        } catch {
            Write-KeystoneLog -Level WARN -Message "GetBranches: $($_.Exception.Message)"
        }
        return $all
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
            return (Get-KeystoneRemoteMapFromZip -ZipPath $tmp)
        } catch {
            Write-KeystoneLog -Level INFO -Message "Remote map unavailable (empty branch?): $($_.Exception.Message)"
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
        $localMap = Get-KeystoneLocalFileMap -Root $localPath
        if ($localMap.Count -eq 0) {
            throw "No files to push under $localPath"
        }
        $remoteMap = $this.TryGetRemoteFileMap($projectPath, $branch)
        $diff = Get-KeystonePathDiff -LocalMap $localMap -RemoteMap $remoteMap
        Write-KeystoneLog -Level INFO -Message ("Diff new={0} mod={1} del={2}" -f @($diff.New).Count, @($diff.Modified).Count, @($diff.Deleted).Count)

        $actions = New-KeystonePushActions -LocalPath $localPath -Diff $diff -DeletePolicy $deletePolicy
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

        $batches = Split-KeystonePushBatches -Actions $actions -Branch $branch -Message $message
        $commits = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($batch in $batches) {
            $i++
            $msg = if ($batches.Count -eq 1) { $message } else { "$message ($i/$($batches.Count))" }
            Write-KeystoneLog -Level INFO -Message ("Commit batch {0}/{1} actions={2}" -f $i, $batches.Count, @($batch).Count)
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
