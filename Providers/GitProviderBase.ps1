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

function New-KeystoneProvider {
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
            if (-not $BaseUrl) { $BaseUrl = "https://web.git.mil" }
            return [GitLabProvider]::new($BaseUrl, $Token)
        }
    }
}

function Resolve-KeystoneProviderFromUrl {
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

function Parse-KeystoneRepoUrl {
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

    if (Test-KeystoneDevRepositoryUrl -Url $Url) {
        $devBase = Get-KeystoneDevProvider
        return [PSCustomObject]@{ Provider = 'GitHub'; BaseUrl = $devBase; ProjectPath = $Url.Substring($devBase.Length).Trim('/') }
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
        $provider = Resolve-KeystoneProviderFromUrl $base
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
