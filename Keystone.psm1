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
. (Join-Path $script:KeystoneRoot "Core\HttpClient.ps1")
. (Join-Path $script:KeystoneRoot "Core\Configuration.ps1")
. (Join-Path $script:KeystoneRoot "Core\Audit.ps1")
. (Join-Path $script:KeystoneRoot "Core\Credentials.ps1")
. (Join-Path $script:KeystoneRoot "Core\Diff.ps1")
. (Join-Path $script:KeystoneRoot "Core\SmartSave.ps1")
. (Join-Path $script:KeystoneRoot "Core\Workspace.ps1")
. (Join-Path $script:KeystoneRoot "Core\Sentinel.ps1")
. (Join-Path $script:KeystoneRoot "Core\RepositoryInsights.ps1")
. (Join-Path $script:KeystoneRoot "Core\AI.ps1")
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
    # Environment, then Keystone's DPAPI store, then ARC if explicitly configured.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('GitHub','GitLab')][string]$Provider)
    $credential = Resolve-KeystoneCredential -Provider $Provider
    Write-KeystoneLog -Level INFO -Message "Credential source for $($Provider): $($credential.Source) (value not logged)."
    return $credential.Value
}

function Open-KeystoneRepository {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token
    )
    Assert-KeystoneTrustedRepositoryUrl -Url $Url
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
    try {
        $project = $prov.ResolveProject($parsed.ProjectPath)
        if (-not $project) { throw 'Empty provider response.' }
    } catch {
        $message = [string]$_.Exception.Message
        # Do not pass raw API responses/headers to the web browser.
        if ($message -match '\b401\b|unauthorized|bad credentials') {
            throw "GIT_AUTH_FAILED|$($parsed.Provider) rejected the credential. Check the ARC item and token permissions."
        } elseif ($message -match '\b403\b|forbidden|resource not accessible') {
            throw "GIT_PERMISSION_DENIED|$($parsed.Provider) denied access. Verify repository membership, SSO authorization, and token scopes."
        } elseif ($message -match '\b404\b|not found') {
            throw "GIT_REPOSITORY_NOT_FOUND|Repository not found or not visible to this credential. Check the URL and repository access."
        }
        throw "GIT_CONNECTION_FAILED|Cannot verify repository access. Inspect the Keystone host diagnostics and check the approved network endpoint."
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

function Invoke-KeystonePull {
    [CmdletBinding()]
    param($Session, [string]$Branch, [string]$LocalPath)
    if (-not $Session) { throw 'Open a repository first.' }
    if (-not $Branch) { $Branch = $Session.DefaultBranch }
    if (-not $LocalPath) {
        $LocalPath = Get-KeystoneSafeWorkspacePath -Base (Join-Path $script:KeystoneRoot 'work') -Project $Session.ProjectPath -Branch $Branch
    }
    # Never delete, replace, or silently merge local files with a downloaded snapshot.
    if (Test-Path -LiteralPath $LocalPath) {
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) { throw 'Download target is not a folder.' }
        if (@(Get-ChildItem -LiteralPath $LocalPath -Force -ErrorAction Stop).Count -gt 0) {
            throw 'Destination contains files. To prevent data loss, choose a new empty folder for this download.'
        }
    }
    $head = Get-KeystoneRemoteHead -Session $Session -Branch $Branch
    if (-not $head) { throw "Branch '$Branch' has no downloadable commit. Initialize the repository first." }
    $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ("keystone-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("keystone-ex-{0}" -f [guid]::NewGuid().ToString('N'))
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
        Copy-KeystoneTree -Source $src -Destination $LocalPath
        $Session.LocalPath = [IO.Path]::GetFullPath($LocalPath)
        $Session.LastBranch = $Branch
        $Session.BaselineSha = $head
        $Session.BaselineMap = Get-KeystoneLocalFileMap -Root $Session.LocalPath
        Write-KeystoneLog -Level INFO -Message "Workspace downloaded at commit $head -> $LocalPath"
        return $Session.LocalPath
    } finally {
        if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
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
    if ($env:KEYSTONE_ALLOW_LEGACY_BULK_UPLOAD -ne '1') {
        throw 'Legacy full-folder upload is disabled by default. Use verified Smart Save, or require explicit administrative opt-in.'
    }
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
        Write-KeystoneLog -Level INFO -Message "GitHub pull request created: $($review.html_url)"
        return $review
    }
    if ($Session.Provider -eq 'GitLab') {
        $review = $Session.ProviderObj.CreateMergeRequest($Session.ProjectPath,$SourceBranch,$TargetBranch,$Title,$Description)
        Write-KeystoneLog -Level INFO -Message "GitLab merge request created: $($review.web_url)"
        return $review
    }
    throw 'Unknown project provider.'
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
    "Initialize-KeystoneArcAuthentication",
    "Test-KeystoneArcVaultUnlocked",
    "Test-KeystoneArcHelpersAvailable",
    "Get-KeystoneArcConnectionStatus",
    "Get-KeystoneArcRequiredFiles",
    "Get-KeystoneArcMissingFiles",
    "Get-KeystoneArcHelperDiagnostics",
    "Convert-KeystoneArcVaultRows",
    "Get-KeystoneArcServiceNames",
    "Set-KeystoneArcItemName",
    "Get-KeystoneLocalArcMappings",
    "Find-KeystoneArcRoot",
    "Get-KeystoneArcSecretByName",
    "Get-KeystoneConfig",
    "Save-KeystoneConfig",
    "Write-KeystoneLog",
    "Write-KeystoneError",
    "Get-KeystoneArcItemName",
    "Get-KeystoneArcCanonicalMap",
    "Get-KeystonePathDiff",
    "Get-KeystoneRemoteHead",
    "Get-KeystoneSafeWorkspacePath",
    "New-KeystoneWorkBranch",
    "Test-KeystoneSensitivePath",
    "Assert-KeystoneTrustedRepositoryUrl",
    "Get-KeystoneAiConfiguration",
    "Get-KeystoneAiToken",
    "New-KeystoneAiPayload",
    "Invoke-KeystoneAI",
    "Invoke-KeystoneAIStream",
    "Send-KeystoneSseEvent",
    "Get-KeystoneWorkspacePreview",
    "Invoke-KeystoneWorkspaceSave",
    "New-KeystoneSmartMessage",
    "Get-KeystoneSmartSavePrompt",
    "Get-KeystoneLocalFileMap",
    "Get-KeystoneSafeName",
    "Clear-KeystoneInputBuffer",
    "Write-KeystoneBreadcrumb",
    # Used by Start-KeystoneWeb.ps1 (tests/ProviderSafety.Tests.ps1 checks the host
    # only calls exported functions).
    "Get-KeystoneRepositoryBranches",
    "Get-KeystoneRepositoryHistory",
    "Get-KeystoneRepositoryComparison",
    "Get-KeystoneRepositoryReviews",
    "Get-KeystoneRepositoryInsights",
    "Get-KeystoneSentinelDestination",
    "Test-KeystoneSentinelPublication",
    "Get-KeystoneSafeErrorMessage",
    "Get-KeystoneArcFlavor",
    "Get-KeystoneArcCredential",
    "Resolve-KeystoneCredential",
    "Get-KeystoneCredentialStatus",
    "Set-KeystoneStoredCredential",
    "Remove-KeystoneStoredCredential",
    "Get-KeystoneStoredCredential",
    "Test-KeystoneCredentialStoreAvailable",
    "Get-KeystoneLocalSettings",
    "Set-KeystoneArcSettings",
    "Get-KeystoneConfiguredArcPath",
    "Test-KeystoneArcConfigured",
    "Write-KeystoneAudit",
    "Get-KeystoneAuditEntries",
    "Get-KeystoneHttpStatus",
    "ConvertTo-KeystoneRefPath"
)
