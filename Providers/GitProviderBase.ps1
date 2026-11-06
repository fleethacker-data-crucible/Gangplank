#Requires -Version 5.1
# ============================================================
#  Providers/GitProviderBase.ps1
#  Abstract contract for GitLab / GitHub / future providers
#  PS classes: no default parameter values on methods.
# ============================================================

class GitProviderBase {
    [string]$Name
    [string]$BaseUrl
    [string]$Token
    [string]$ApiRoot

    GitProviderBase([string]$name, [string]$baseUrl, [string]$token) {
        $this.Name    = $name
        $this.BaseUrl = $baseUrl.TrimEnd('/')
        $this.Token   = $token
        $this.ApiRoot = $null
    }

    [hashtable] GetAuthHeaders([string]$method) {
        throw "GetAuthHeaders must be implemented by provider"
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body, [string]$outFile) {
        throw "InvokeApi must be implemented by provider"
    }

    [object] InvokeApi([string]$method, [string]$endpoint) {
        return $this.InvokeApi($method, $endpoint, $null, $null)
    }

    [object] InvokeApi([string]$method, [string]$endpoint, [object]$body) {
        return $this.InvokeApi($method, $endpoint, $body, $null)
    }

    [object] ResolveProject([string]$projectPath) {
        throw "ResolveProject must be implemented"
    }

    [string[]] GetBranches([string]$projectPath) {
        throw "GetBranches must be implemented"
    }

    [string] GetDefaultBranch([string]$projectPath) {
        throw "GetDefaultBranch must be implemented"
    }

    [void] DownloadArchive([string]$projectPath, [string]$ref, [string]$outZip) {
        throw "DownloadArchive must be implemented"
    }

    [string] GetDisplayName() {
        return $this.Name
    }
}

function New-GangplankProvider {
    param(
        [ValidateSet("GitLab","GitHub")]
        [string]$Provider,
        [string]$BaseUrl,
        [string]$Token
    )
    switch ($Provider) {
        "GitHub" {
            if (-not $BaseUrl) { $BaseUrl = "https://api.github.com" }
            return [GitHubProvider]::new($BaseUrl, $Token)
        }
        default {
            if (-not $BaseUrl) {
                $gitLabHost = Get-GangplankGitLabHost
                if (-not $gitLabHost) { throw "GitLab host is not configured. Set GANGPLANK_GITLAB_HOST or GitLabHost in config\gangplank-config.json." }
                $BaseUrl = "https://$gitLabHost"
            }
            return [GitLabProvider]::new($BaseUrl, $Token)
        }
    }
}

function Resolve-GangplankProviderFromUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return "GitLab" }
    try {
        $u = [uri]$Url
        $h = $u.Host.ToLowerInvariant()
        if ($h -eq "github.com" -or $h -eq "api.github.com" -or $h -like "*.github.com") {
            return "GitHub"
        }
    } catch { }
    return "GitLab"
}

function Parse-GangplankRepoUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "Empty repository URL"
    }
    $Url = $Url.Trim()
    $hash = $Url.IndexOf('#')
    if ($hash -ge 0) { $Url = $Url.Substring(0, $hash) }
    $q = $Url.IndexOf('?')
    if ($q -ge 0) { $Url = $Url.Substring(0, $q) }
    $Url = $Url.TrimEnd('/')
    if ($Url -match '\.git$') { $Url = $Url.Substring(0, $Url.Length - 4) }

    $dev = Resolve-GangplankDevRepository -Url $Url
    if ($dev) {
        return [PSCustomObject]@{ Provider = $dev.Provider; BaseUrl = $dev.BaseUrl; ProjectPath = $Url.Substring($dev.BaseUrl.Length).Trim('/') }
    }
    if ($Url -match '^(https?://[^/]+)/(.+)$') {
        $base = $Matches[1]
        $path = $Matches[2]
        $cut = $path.IndexOf('/-/')
        if ($cut -ge 0) { $path = $path.Substring(0, $cut) }
        foreach ($m in @('/tree/','/blob/','/raw/','/commit/','/commits/','/pull/','/pulls/','/issues/','/actions/')) {
            $idx = $path.IndexOf($m)
            if ($idx -gt 0) { $path = $path.Substring(0, $idx) }
        }
        $path = $path.Trim('/')
        $provider = Resolve-GangplankProviderFromUrl $base
        if ($provider -eq "GitHub" -and $base -match 'github\.com$') {
            $base = "https://github.com"
        }
        return [PSCustomObject]@{
            Provider    = $provider
            BaseUrl     = $base
            ProjectPath = $path
        }
    }
    throw "Invalid repository URL. Paste the full browser URL."
}

function Resolve-GangplankConnectTarget {
    # A GitHub URL is a repository (owner/name), an organization
    # (/orgs/name or /orgs/name/repositories), a user profile
    # (/users/name or /users/name/repositories), or a single owner name
    # that the API must classify. GitLab URLs stay repositories.
    param([Parameter(Mandatory)][string]$Url)
    Assert-GangplankTrustedRepositoryUrl -Url $Url
    $parsed = Parse-GangplankRepoUrl -Url $Url
    $mode = 'repository'
    $owner = ''
    if ($parsed.Provider -eq 'GitHub') {
        $parts = @($parsed.ProjectPath -split '/' | Where-Object { $_ })
        if ($parts.Count -eq 1) {
            $mode = 'owner'
            $owner = $parts[0]
        } elseif ($parts.Count -ge 2 -and ($parts[0] -eq 'orgs' -or $parts[0] -eq 'users')) {
            $tailOk = ($parts.Count -eq 2) -or ($parts.Count -eq 3 -and $parts[2] -eq 'repositories')
            if (-not $tailOk) {
                if ($parts[0] -eq 'orgs') { throw 'BAD_REQUEST|Use the organization URL, for example https://github.com/orgs/name or https://github.com/name.' }
                throw 'BAD_REQUEST|Use the profile URL, for example https://github.com/users/name or https://github.com/name.'
            }
            $mode = $(if ($parts[0] -eq 'orgs') { 'organization' } else { 'user' })
            $owner = $parts[1]
        }
    }
    if ($mode -ne 'repository') {
        if ($owner -notmatch '^[A-Za-z0-9]([A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$') {
            throw 'BAD_REQUEST|That organization or user name is not a valid GitHub name.'
        }
    }
    return [pscustomobject]@{
        Provider    = $parsed.Provider
        BaseUrl     = $parsed.BaseUrl
        ProjectPath = $parsed.ProjectPath
        Mode        = $mode
        Owner       = $owner
    }
}
