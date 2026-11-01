#Requires -Version 5.1
# ============================================================
#  Gangplank.psm1 - Phase A/B modular entry
#  GitLab pull / push / MR + GitHub push (no git.exe)
# ============================================================

$ErrorActionPreference = "Stop"

$script:GangplankRoot = $PSScriptRoot
if (-not $script:GangplankRoot) {
    $script:GangplankRoot = (Get-Location).Path
}

. (Join-Path $script:GangplankRoot "Core\Logging.ps1")
. (Join-Path $script:GangplankRoot "Core\Utils.ps1")
. (Join-Path $script:GangplankRoot "Core\HttpClient.ps1")
. (Join-Path $script:GangplankRoot "Core\Configuration.ps1")
. (Join-Path $script:GangplankRoot "Core\Audit.ps1")
. (Join-Path $script:GangplankRoot "Core\Credentials.ps1")
. (Join-Path $script:GangplankRoot "Core\WorkspaceBaseline.ps1")
. (Join-Path $script:GangplankRoot "Core\AiConsent.ps1")
. (Join-Path $script:GangplankRoot "Core\Adopt.ps1")
. (Join-Path $script:GangplankRoot "Core\Diff.ps1")
. (Join-Path $script:GangplankRoot "Core\SmartSave.ps1")
. (Join-Path $script:GangplankRoot "Core\Workspace.ps1")
. (Join-Path $script:GangplankRoot "Core\GetLatest.ps1")
. (Join-Path $script:GangplankRoot "Core\Revert.ps1")
. (Join-Path $script:GangplankRoot "Core\Sentinel.ps1")
. (Join-Path $script:GangplankRoot "Core\RepositoryInsights.ps1")
. (Join-Path $script:GangplankRoot "Core\Reviews.ps1")
. (Join-Path $script:GangplankRoot "Core\Intelligence.ps1")
. (Join-Path $script:GangplankRoot "Core\AI.ps1")
. (Join-Path $script:GangplankRoot "LazaretteBridge.ps1")
. (Join-Path $script:GangplankRoot "Providers\GitProviderBase.ps1")
. (Join-Path $script:GangplankRoot "Providers\GitLabProvider.ps1")
. (Join-Path $script:GangplankRoot "Providers\GitHubProvider.ps1")
. (Join-Path $script:GangplankRoot "Core\Lifecycle.ps1")
. (Join-Path $script:GangplankRoot "Server\Session.ps1")
. (Join-Path $script:GangplankRoot "Server\Jobs.ps1")
. (Join-Path $script:GangplankRoot "Server\JobWork.ps1")
. (Join-Path $script:GangplankRoot "Server\Http.ps1")
. (Join-Path $script:GangplankRoot "Server\Routes.ps1")
. (Join-Path $script:GangplankRoot "Server\WebHost.ps1")


function Write-GangplankBreadcrumb {
    param([string]$Step)
    try {
        $p = Join-Path $script:GangplankRoot "Logs\last-step.txt"
        $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Step
        Set-Content -LiteralPath $p -Value $line -Encoding ASCII
        Write-GangplankLog -Level INFO -Message $Step
    } catch { }
}

function Initialize-Gangplank {
    # -ConfigPath isolates settings (tests, LocalDev); normally config\ in the tool folder.
    param([string]$LogLevel = "INFO",[string]$ConfigPath)
    Initialize-GangplankLogging -LogDir (Join-Path $script:GangplankRoot "Logs") -Level $LogLevel
    if (-not $ConfigPath) { $ConfigPath = Join-Path $script:GangplankRoot "config\gangplank-config.json" }
    Initialize-GangplankConfig -ConfigPath $ConfigPath
    Write-GangplankLog -Level INFO -Message "Gangplank $($script:GangplankRoot)"
}

function Get-GangplankToken {
    # Environment, then Gangplank's DPAPI store, then Lazarette if explicitly configured.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('GitHub','GitLab')][string]$Provider,[string]$TargetHost)
    $credential = Resolve-GangplankCredential -Provider $Provider -TargetHost $TargetHost
    Write-GangplankLog -Level INFO -Message "Credential source for $($Provider): $($credential.Source) (value not logged)."
    return $credential.Value
}

function Open-GangplankRepository {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token
    )
    Assert-GangplankTrustedRepositoryUrl -Url $Url
    $parsed = Parse-GangplankRepoUrl -Url $Url
    Write-GangplankLog -Level INFO -Message "Provider=$($parsed.Provider) Path=$($parsed.ProjectPath)"

    if (-not $Token) {
        $targetHost = ''
        try { $targetHost = ([uri][string]$parsed.BaseUrl).Host } catch { $targetHost = '' }
        $Token = Get-GangplankToken -Provider $parsed.Provider -TargetHost $targetHost
    }
    if (-not $Token) {
        throw "No token for $($parsed.Provider). Set env or Lazarette Service name."
    }

    $prov = New-GangplankProvider -Provider $parsed.Provider -BaseUrl $parsed.BaseUrl -Token $Token
    $project = $null
    try {
        $project = $prov.ResolveProject($parsed.ProjectPath)
        if (-not $project) { throw 'Empty provider response.' }
    } catch {
        $message = [string]$_.Exception.Message
        # Do not pass raw API responses/headers to the web browser.
        if ($message -match '\b401\b|unauthorized|bad credentials') {
            throw "GIT_AUTH_FAILED|$($parsed.Provider) rejected the credential. Check the Lazarette item and token permissions."
        } elseif ($message -match '\b403\b|forbidden|resource not accessible') {
            throw "GIT_PERMISSION_DENIED|$($parsed.Provider) denied access. Verify repository membership, SSO authorization, and token scopes."
        } elseif ($message -match '\b404\b|not found') {
            throw "GIT_REPOSITORY_NOT_FOUND|Repository not found or not visible to this credential. Check the URL and repository access."
        }
        throw "GIT_CONNECTION_FAILED|Cannot verify repository access. Inspect the Gangplank host diagnostics and check the approved network endpoint."
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
        BaselineSha   = $null
        BaselineMap   = @{}
    }
}

function Invoke-GangplankPull {
    [CmdletBinding()]
    param($Session, [string]$Branch, [string]$LocalPath)
    if (-not $Session) { throw 'Open a repository first.' }
    if (-not $Branch) { $Branch = $Session.DefaultBranch }
    if (-not $LocalPath) {
        $LocalPath = Get-GangplankSafeWorkspacePath -Base (Join-Path $script:GangplankRoot 'work') -Project $Session.ProjectPath -Branch $Branch
    }
    # Never delete, replace, or silently merge local files with a downloaded snapshot.
    if (Test-Path -LiteralPath $LocalPath) {
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) { throw 'Download target is not a folder.' }
        if (@(Get-ChildItem -LiteralPath $LocalPath -Force -ErrorAction Stop).Count -gt 0) {
            throw 'Destination contains files. To prevent data loss, choose a new empty folder for this download.'
        }
    }
    $head = Get-GangplankRemoteHead -Session $Session -Branch $Branch
    if (-not $head) { throw "Branch '$Branch' has no downloadable commit. Initialize the repository first." }
    $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ("gangplank-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("gangplank-ex-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        # Download a fixed commit, not a moving branch tip.
        $Session.ProviderObj.DownloadArchive($Session.ProjectPath,$head,$tmpZip)
        if (-not (Test-Path -LiteralPath $tmpZip) -or (Get-Item -LiteralPath $tmpZip).Length -eq 0) {
            throw 'Repository archive was empty.'
        }
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
        $roots = @(Get-ChildItem -LiteralPath $tmpDir -Force)
        $src = if ($roots.Count -eq 1 -and $roots[0].PSIsContainer) { $roots[0].FullName } else { $tmpDir }
        if (-not (Test-Path -LiteralPath $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }
        Copy-GangplankTree -Source $src -Destination $LocalPath
        $Session.LocalPath = [IO.Path]::GetFullPath($LocalPath)
        $Session.LastBranch = $Branch
        $Session.BaselineSha = $head
        $Session.BaselineMap = Get-GangplankLocalFileMap -Root $Session.LocalPath
        Write-GangplankLog -Level INFO -Message "Workspace downloaded at commit $head -> $LocalPath"
        return $Session.LocalPath
    } finally {
        if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function New-GangplankMergeRequest {
    [CmdletBinding()]
    param(
        $Session,
        [string]$SourceBranch,
        [string]$TargetBranch,
        [string]$Title,
        [string]$Description = ''
    )
    if (-not $Session) { throw 'Open a project first.' }
    if (-not $SourceBranch) { $SourceBranch = $Session.LastBranch }
    if (-not $TargetBranch) { $TargetBranch = $Session.DefaultBranch }
    if (-not $SourceBranch -or -not $TargetBranch) { throw 'Source and target branches are required.' }
    if ([string]::IsNullOrWhiteSpace($Title)) { throw 'Review title is required.' }
    if ($Session.Provider -eq 'GitHub') {
        $review = $Session.ProviderObj.CreatePullRequest($Session.ProjectPath,$SourceBranch,$TargetBranch,$Title,$Description)
        Write-GangplankLog -Level INFO -Message "GitHub pull request created: $($review.html_url)"
        Write-GangplankAudit -Action 'review.created' -Data @{ provider = 'GitHub'; project = $Session.ProjectPath; source = $SourceBranch; target = $TargetBranch; url = [string]$review.html_url }
        return $review
    }
    if ($Session.Provider -eq 'GitLab') {
        $review = $Session.ProviderObj.CreateMergeRequest($Session.ProjectPath,$SourceBranch,$TargetBranch,$Title,$Description)
        Write-GangplankLog -Level INFO -Message "GitLab merge request created: $($review.web_url)"
        Write-GangplankAudit -Action 'review.created' -Data @{ provider = 'GitLab'; project = $Session.ProjectPath; source = $SourceBranch; target = $TargetBranch; url = [string]$review.web_url }
        return $review
    }
    throw 'Unknown project provider.'
}

Export-ModuleMember -Function @(
    "Initialize-Gangplank",
    "Get-GangplankToken",
    "Open-GangplankRepository",
    "Invoke-GangplankPull",
    "New-GangplankMergeRequest",
    "Show-GangplankMenu",
    "Show-GangplankBanner",
    "Wait-GangplankEnter",
    "Select-GangplankFolder",
    "Get-GangplankSuggestedWorkPath",
    "Parse-GangplankRepoUrl",
    "Resolve-GangplankProviderFromUrl",
    "New-GangplankProvider",
    "Import-GangplankLazaretteSession",
    "Initialize-GangplankLazaretteAuthentication",
    "Test-GangplankLazaretteVaultUnlocked",
    "Test-GangplankLazaretteHelpersAvailable",
    "Get-GangplankLazaretteConnectionStatus",
    "Get-GangplankLazaretteHelperDiagnostics",
    "Get-GangplankLazaretteServiceNames",
    "Set-GangplankLazaretteItemName",
    "Get-GangplankLocalLazaretteMappings",
    "Find-GangplankLazaretteRoot",
    "Get-GangplankLazaretteSecretByName",
    "Get-GangplankConfig",
    "Save-GangplankConfig",
    "Write-GangplankLog",
    "Write-GangplankError",
    "Get-GangplankLazaretteItemName",
    "Get-GangplankLazaretteCanonicalMap",
    "Get-GangplankConfigLazaretteItems",
    "Get-GangplankPathDiff",
    "Get-GangplankRemoteHead",
    "Get-GangplankSafeWorkspacePath",
    "New-GangplankWorkBranch",
    "Test-GangplankSensitivePath",
    "Assert-GangplankTrustedRepositoryUrl",
    "Get-GangplankAiConfiguration",
    "Get-GangplankAiToken",
    "Get-GangplankAiRequestToken",
    "Get-GangplankAiExplainPreview",
    "Invoke-GangplankAiExplain",
    "Test-GangplankAiLoopbackUrl",
    "Get-GangplankAiAuthHeaders",
    "Get-GangplankFairleadKey",
    "Get-GangplankFairleadTarget",
    "Set-GangplankFairleadKeyReader",
    "Resolve-GangplankFairleadUrl",
    "ConvertFrom-GangplankCredentialBlob",
    "New-GangplankAiPayload",
    "Invoke-GangplankAI",
    "Invoke-GangplankAIStream",
    "Get-GangplankWorkspacePreview",
    "Add-GangplankExistingFolder",
    "Invoke-GangplankWorkspaceSave",
    "Update-GangplankWorkspaceFromRemote",
    "Restore-GangplankWorkspaceFile",
    "New-GangplankSmartMessage",
    "Get-GangplankSmartSavePrompt",
    "Get-GangplankLocalFileMap",
    "Get-GangplankSafeName",
    "Clear-GangplankInputBuffer",
    "Write-GangplankBreadcrumb",
    # Used by Start-Gangplank.ps1 (tests/ProviderSafety.Tests.ps1 checks the host
    # only calls exported functions).
    "Get-GangplankRepositoryBranches",
    "Get-GangplankRepositoryHistory",
    "Get-GangplankRepositoryComparison",
    "Get-GangplankRepositoryReviews",
    "Get-GangplankReviewDetail",
    "Add-GangplankReviewComment",
    "Merge-GangplankReview",
    "Get-GangplankRepositoryInsights",
    "Get-GangplankSentinelDestination",
    "Test-GangplankSentinelPublication",
    "Get-GangplankSafeErrorMessage",
    "Test-GangplankLazaretteFolder",
    "Get-GangplankLazaretteCredential",
    "Resolve-GangplankCredential",
    "Get-GangplankCredentialStatus",
    "Set-GangplankStoredCredential",
    "Remove-GangplankStoredCredential",
    "Get-GangplankStoredCredential",
    "Test-GangplankCredentialStoreAvailable",
    "Get-GangplankLocalSettings",
    "Set-GangplankLazaretteSettings",
    "Get-GangplankConfiguredLazarettePath",
    "Test-GangplankLazaretteConfigured",
    "Write-GangplankAudit",
    "Get-GangplankAuditEntries",
    "Get-GangplankHttpStatus",
    "ConvertTo-GangplankRefPath",
    "Start-GangplankWebHost",
    "Get-GangplankWorkspaceRoot",
    "Get-GangplankAiSettingsView",
    "Test-GangplankAiConnection",
    "ConvertTo-GangplankBranchName",
    "Reset-GangplankPresence",
    "Register-GangplankPresence",
    "Register-GangplankRequestFinished",
    "Test-GangplankBrowserGone",
    "Get-GangplankPresenceState",
    "Test-GangplankAutoStopEnabled",
    "Write-GangplankRuntimeFile",
    "Remove-GangplankRuntimeFile",
    "Get-GangplankServerProcesses",
    "Stop-GangplankServerProcesses",
    "Request-GangplankServerStop",
    "New-GangplankStopEvent",
    "Format-GangplankServerProcess",
    "Test-GangplankJobsBusy",
    "Request-GangplankHostStop",
    "Get-GangplankHostLifecycleState",
    "Get-GangplankEnv",
    "Get-GangplankLazarettePathEnv"
)
