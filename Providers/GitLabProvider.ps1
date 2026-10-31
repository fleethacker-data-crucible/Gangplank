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

    [void] DownloadArchive([string]$projectPath, [string]$ref, [string]$outZip) {
        $enc = $this.EncodePath($projectPath)
        $refEnc = [uri]::EscapeDataString($ref)
        $this.InvokeApi("GET", "projects/$enc/repository/archive.zip?sha=$refEnc", $null, $outZip)
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
