#Requires -Version 5.1
# ============================================================
#  Keystone.psm1 - Phase A/B modular entry
#  GitLab pull / push / MR + GitHub push (no git.exe)
# ============================================================

$ErrorActionPreference = "Stop"

$script:KeystoneRoot = $PSScriptRoot
if (-not $script:KeystoneRoot) {
    $script:KeystoneRoot = (Get-Location).Path
}

. (Join-Path $script:KeystoneRoot "Core\Logging.ps1")
. (Join-Path $script:KeystoneRoot "Core\Utils.ps1")
. (Join-Path $script:KeystoneRoot "Core\Configuration.ps1")
. (Join-Path $script:KeystoneRoot "Core\Diff.ps1")
. (Join-Path $script:KeystoneRoot "ArcBridge.ps1")
. (Join-Path $script:KeystoneRoot "Providers\GitProviderBase.ps1")
. (Join-Path $script:KeystoneRoot "Providers\GitLabProvider.ps1")
. (Join-Path $script:KeystoneRoot "Providers\GitHubProvider.ps1")


function Write-KeystoneBreadcrumb {
    param([string]$Step)
    try {
        $p = Join-Path $script:KeystoneRoot "Logs\last-step.txt"
        $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Step
        Set-Content -LiteralPath $p -Value $line -Encoding ASCII
        Write-KeystoneLog -Level INFO -Message $Step
    } catch { }
}

function Initialize-Keystone {
    param([string]$LogLevel = "INFO")
    Initialize-KeystoneLogging -LogDir (Join-Path $script:KeystoneRoot "Logs") -Level $LogLevel
    Initialize-KeystoneConfig -ConfigPath (Join-Path $script:KeystoneRoot "config\keystone-config.json")
    Write-KeystoneLog -Level INFO -Message "Keystone $($script:KeystoneRoot)"
}

function Get-KeystoneToken {
    param([ValidateSet("GitLab","GitHub")][string]$Provider)
    $envName = if ($Provider -eq "GitHub") { "GITHUB_TOKEN" } else { "GITLAB_TOKEN" }
    if (Test-Path "env:$envName") {
        $v = (Get-Item "env:$envName").Value
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            Write-KeystoneLog -Level INFO -Message "Token from env:$envName"
            return $v.Trim()
        }
    }
    $item = Get-KeystoneArcItemName -Provider $Provider
    Write-KeystoneLog -Level INFO -Message "Resolving ARC Service name '$item' for $Provider"
    $tok = Get-KeystoneArcSecretByName -ServiceName $item
    if ($tok) {
        Write-KeystoneLog -Level INFO -Message "Token from ARC Service '$item' (len=$($tok.Length))"
        return $tok
    }
    Write-KeystoneLog -Level WARN -Message "No token for $Provider (env or ARC Service '$item')"
    return $null
}

function Open-KeystoneRepository {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token
    )
    $parsed = Parse-KeystoneRepoUrl -Url $Url
    Write-KeystoneLog -Level INFO -Message "Provider=$($parsed.Provider) Path=$($parsed.ProjectPath)"

    if (-not $Token) {
        $Token = Get-KeystoneToken -Provider $parsed.Provider
    }
    if (-not $Token) {
        throw "No token for $($parsed.Provider). Set env or ARC Service name."
    }

    $prov = New-KeystoneProvider -Provider $parsed.Provider -BaseUrl $parsed.BaseUrl -Token $Token
    $project = $null
    try { $project = $prov.ResolveProject($parsed.ProjectPath) } catch {
        Write-KeystoneLog -Level WARN -Message "ResolveProject: $($_.Exception.Message)"
    }
    $default = "main"
    try { $default = $prov.GetDefaultBranch($parsed.ProjectPath) } catch { }
    $branches = @()
    try { $branches = @($prov.GetBranches($parsed.ProjectPath)) } catch { }

    return [PSCustomObject]@{
        Provider      = $parsed.Provider
        BaseUrl       = $parsed.BaseUrl
        ProjectPath   = $parsed.ProjectPath
        Project       = $project
        DefaultBranch = $default
        Branches      = $branches
        ProviderObj   = $prov
        LocalPath     = $null
        LastBranch    = $null
    }
}

function Invoke-KeystonePull {
    param($Session, [string]$Branch, [string]$LocalPath)
    if (-not $Branch) { $Branch = $Session.DefaultBranch }
    if (-not $LocalPath) {
        $safe = Get-KeystoneSafeName ($Session.ProjectPath -replace '/', '-')
        $LocalPath = Join-Path $script:KeystoneRoot "work\$safe\$Branch"
    }
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
        Write-KeystoneLog -Level INFO -Message "Created local folder: $LocalPath"
    }

    # Empty branch list => likely empty repo; skip hard failure
    $branchCount = 0
    try { $branchCount = @($Session.Branches).Count } catch { }
    if ($branchCount -eq 0) {
        Write-KeystoneLog -Level WARN -Message "No remote branches for $($Session.ProjectPath) - empty repo; nothing to pull"
        throw "EMPTY_REPO|Branch list is empty. Use Share my folder to create the first commit, then Get latest works."
    }

    $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ("keystone-{0}.zip" -f [guid]::NewGuid().ToString("N"))
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("keystone-ex-{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        Write-KeystoneLog -Level INFO -Message "Downloading $($Session.Provider) $($Session.ProjectPath)@$Branch"
        try {
            $Session.ProviderObj.DownloadArchive($Session.ProjectPath, $Branch, $tmpZip)
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match '404|Not Found|empty') {
                throw "EMPTY_REPO|No archive for branch '$Branch'. Repo may be empty - Share my folder first. ($msg)"
            }
            throw
        }
        if (-not (Test-Path $tmpZip) -or ((Get-Item $tmpZip).Length -eq 0)) {
            throw "EMPTY_REPO|Archive empty for '$Branch'. Share my folder first."
        }
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        $top = Get-ChildItem $tmpDir -Force | Select-Object -First 1
        $src = if ($top -and $top.PSIsContainer) { $top.FullName } else { $tmpDir }
        Get-ChildItem $LocalPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Copy-KeystoneTree -Source $src -Destination $LocalPath
        Write-KeystoneLog -Level INFO -Message "Pulled '$Branch' into $LocalPath"
        return $LocalPath
    } finally {
        if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-KeystonePush {
    param(
        $Session,
        [Parameter(Mandatory)][string]$LocalPath,
        [string]$Branch,
        [string]$Message,
        [ValidateSet("Omit","Include")]
        [string]$DeletePolicy = "Omit"
    )
    if (-not $Session) { throw "Open a repository first." }
    if (-not $Branch) {
        $Branch = if ($Session.DefaultBranch) { $Session.DefaultBranch } else { "main" }
    }
    if (-not $Message) {
        $Message = "Commit from Keystone ({0})" -f (Get-Date -Format "yyyy-MM-dd HH:mm")
    }
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "Local path not found: $LocalPath"
    }

    Write-KeystoneLog -Level INFO -Message "Push $LocalPath -> $($Session.Provider) $($Session.ProjectPath)@$Branch"

    if ($Session.Provider -eq "GitLab") {
        $result = $Session.ProviderObj.PushFolder(
            $Session.ProjectPath, $Branch, $LocalPath, $Message, $DeletePolicy
        )
        Write-KeystoneLog -Level INFO -Message "GitLab push actions=$($result.FileCount) commits=$($result.Commits -join ',')"
        return $result
    }

    if ($Session.Provider -eq "GitHub") {
        $result = $Session.ProviderObj.PushFolder(
            $Session.ProjectPath, $Branch, $LocalPath, $Message,
            @("Logs", "work", ".git", ".vs", "node_modules")
        )
        Write-KeystoneLog -Level INFO -Message "GitHub push files=$($result.FileCount) commit=$($result.CommitSha)"
        return $result
    }

    throw "Unknown provider $($Session.Provider)"
}

function New-KeystoneMergeRequest {
    param(
        $Session,
        [string]$SourceBranch,
        [string]$TargetBranch,
        [string]$Title,
        [string]$Description = ""
    )
    if ($Session.Provider -ne "GitLab") {
        throw "Create MR is GitLab-only in Phase A/B. GitHub PR is Phase C."
    }
    if (-not $SourceBranch) { $SourceBranch = $Session.LastBranch }
    if (-not $TargetBranch) { $TargetBranch = $Session.DefaultBranch }
    if (-not $Title) { throw "MR title required" }

    $mr = $Session.ProviderObj.CreateMergeRequest(
        $Session.ProjectPath, $SourceBranch, $TargetBranch, $Title, $Description
    )
    Write-KeystoneLog -Level INFO -Message "MR created $($mr.web_url)"
    return $mr
}

Export-ModuleMember -Function @(
    "Initialize-Keystone",
    "Get-KeystoneToken",
    "Open-KeystoneRepository",
    "Invoke-KeystonePull",
    "Invoke-KeystonePush",
    "New-KeystoneMergeRequest",
    "Show-KeystoneMenu",
    "Show-KeystoneBanner",
    "Wait-KeystoneEnter",
    "Select-KeystoneFolder",
    "Get-KeystoneSuggestedWorkPath",
    "Parse-KeystoneRepoUrl",
    "Resolve-KeystoneProviderFromUrl",
    "New-KeystoneProvider",
    "Import-KeystoneArcSession",
    "Find-KeystoneArcRoot",
    "Get-KeystoneArcSecretByName",
    "Get-KeystoneConfig",
    "Save-KeystoneConfig",
    "Write-KeystoneLog",
    "Write-KeystoneError",
    "Get-KeystoneArcItemName",
    "Get-KeystoneArcCanonicalMap",
    "Get-KeystonePathDiff",
    "Get-KeystoneLocalFileMap",
    "Get-KeystoneSafeName",
    "Clear-KeystoneInputBuffer",
    "Write-KeystoneBreadcrumb"
)
