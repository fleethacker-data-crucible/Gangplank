#Requires -Version 5.1
# =============================================================================
# Gangplank API routes. Only reached through Invoke-GangplankServerRequest, after
# the loopback, client-header and session-cookie checks. Long operations start
# a background job and answer 202 { job }; the UI polls /api/jobs/{id}.
# Errors are { error: CODE, message } with a safe one-line message.
# =============================================================================

$script:GangplankApp = @{
    Session = $null        # live session (with provider object) or $null
    Restored = $null       # snapshot from a previous run, waiting for a token
    WorkRoot = ''
    WorkRootFixed = $false
    StateRoot = ''
    LocalDev = $false
    Generation = 0         # bumped on connect/disconnect; stale job results are dropped
}

function Initialize-GangplankApp {
    # WorkRoot: where workspaces go. StateRoot: Gangplank's own data (saved session).
    # LegacyStateRoot: the old <tool>\work\.keystone, read once if nothing newer exists.
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$StateRoot,[string]$LegacyStateRoot,[switch]$WorkRootFixed,[switch]$LocalDev)
    $script:GangplankApp.WorkRoot = $WorkRoot
    $script:GangplankApp.WorkRootFixed = [bool]$WorkRootFixed
    $script:GangplankApp.StateRoot = $StateRoot
    $script:GangplankApp.LocalDev = [bool]$LocalDev
    $script:GangplankApp.Session = $null
    $script:GangplankApp.Restored = Read-GangplankSessionState -StateRoot $StateRoot
    if (-not $script:GangplankApp.Restored -and $LegacyStateRoot -and (Test-Path -LiteralPath (Get-GangplankSessionStatePath -StateRoot $LegacyStateRoot))) {
        $script:GangplankApp.Restored = Read-GangplankSessionState -StateRoot $LegacyStateRoot
        if ($script:GangplankApp.Restored) {
            Write-GangplankLog -Level INFO -Message 'Picked up the session saved by an earlier Keystone (work\.keystone). New workspaces now go to the workspace folder.'
            try { Save-GangplankSessionState -StateRoot $StateRoot -Session ([pscustomobject]$script:GangplankApp.Restored) } catch { }
        }
    }
    if ($script:GangplankApp.Restored) {
        Write-GangplankLog -Level INFO -Message "Restored session for $($script:GangplankApp.Restored.ProjectPath) (branch $($script:GangplankApp.Restored.LastBranch))."
    }
}

function Get-GangplankAppSnapshot {
    if ($script:GangplankApp.Session) { return (ConvertTo-GangplankSessionSnapshot $script:GangplankApp.Session) }
    return $script:GangplankApp.Restored
}

function Get-GangplankLiveSession {
    # The live session, rebuilding a restored one once a credential is available.
    param([switch]$Required)
    if (-not $script:GangplankApp.Session -and $script:GangplankApp.Restored) {
        try {
            $token = (Resolve-GangplankCredential -Provider $script:GangplankApp.Restored.Provider).Value
            $script:GangplankApp.Session = New-GangplankSessionFromSnapshot -Snapshot $script:GangplankApp.Restored -Token $token
            $script:GangplankApp.Restored = $null
        } catch {
            if ($Required) { throw }
        }
    }
    if ($Required -and -not $script:GangplankApp.Session) { throw 'NOT_CONNECTED|Connect a project first.' }
    return $script:GangplankApp.Session
}

function Set-GangplankAppSession {
    param($Snapshot,[string]$Token)
    if (-not $Snapshot) {
        $script:GangplankApp.Session = $null
        $script:GangplankApp.Restored = $null
    } else {
        if (-not $Token) { $Token = (Resolve-GangplankCredential -Provider $Snapshot.Provider).Value }
        $script:GangplankApp.Session = New-GangplankSessionFromSnapshot -Snapshot $Snapshot -Token $Token
        $script:GangplankApp.Restored = $null
    }
    # Saving state is best effort (antivirus, sync clients): never fail the request for it.
    try { Save-GangplankSessionState -StateRoot $script:GangplankApp.StateRoot -Session $script:GangplankApp.Session }
    catch { Write-GangplankLog -Level WARN -Message "Session state could not be saved: $($_.Exception.Message)" }
}

function Update-GangplankSessionCredential {
    # After a token is saved or removed, rebuild the live provider so quick reads use it.
    param([string]$Provider)
    $s = $script:GangplankApp.Session
    if (-not $s -or $s.Provider -ne $Provider) { return }
    try {
        $token = (Resolve-GangplankCredential -Provider $Provider).Value
        $script:GangplankApp.Session = New-GangplankSessionFromSnapshot -Snapshot (ConvertTo-GangplankSessionSnapshot $s) -Token $token
    } catch {
        # No credential any more: keep the work as a restorable snapshot.
        $script:GangplankApp.Restored = ConvertTo-GangplankSessionSnapshot $s
        $script:GangplankApp.Session = $null
    }
}

function Get-GangplankAppSettingsView {
    return [ordered]@{
        workspaces = [ordered]@{
            root = $script:GangplankApp.WorkRoot
            default = (Get-GangplankDefaultWorkspaceRoot)
            fixed = [bool]($script:GangplankApp.WorkRootFixed -or -not [string]::IsNullOrWhiteSpace((Get-GangplankEnv WORK_ROOT)))
        }
        intelligence = (Get-GangplankAiSettingsView)
    }
}

function Get-GangplankErrorStatus {
    param([string]$Code)
    switch -Regex ($Code) {
        '^(BAD_REQUEST|INVALID)' { return 400 }
        '^(NOT_FOUND)$' { return 404 }
        '^(BUSY|CONFLICT|NOT_CONNECTED|BAD_STATE|CREDENTIAL_MISSING|CREDENTIAL_STORE_UNAVAILABLE|ARC_[A-Z_]+|AI_NOT_CONFIGURED|GIT_[A-Z_]+)$' { return 409 }
        '^(AUTH_REJECTED|FORBIDDEN|RATE_LIMITED|SERVER_ERROR|NETWORK)$' { return 502 }
        default { return 400 }
    }
}

function Split-GangplankCodedMessage {
    param([string]$Message)
    $safe = Get-GangplankSafeErrorMessage -Message $Message
    if ($safe -match '^([A-Z][A-Z0-9_]{2,40})\|(.*)$') { return @{ Code = $Matches[1]; Message = $Matches[2].Trim() } }
    return @{ Code = 'FAILED'; Message = $safe }
}

function Get-GangplankBodyValue {
    param($Req,[string]$Name)
    if ($null -eq $Req.Json) { return $null }
    $p = $Req.Json.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-GangplankJobContext {
    # Main-thread context for a workspace job: which session generation it belongs
    # to, and the token to reuse when its result is applied.
    param([string]$Token,[string]$Kind)
    return @{ Generation = $script:GangplankApp.Generation; Token = $Token; Kind = $Kind }
}

function Get-GangplankJobArguments {
    # Snapshot + token for workspace jobs; the token never leaves this process.
    param([Parameter(Mandatory)]$Session)
    return @{
        Session = (ConvertTo-GangplankSessionSnapshot $Session)
        Token = (Resolve-GangplankCredential -Provider $Session.Provider).Value
        WorkRoot = $script:GangplankApp.WorkRoot
        DevGitHubUrl = (Get-GangplankDevProvider)
    }
}

# Job completion handlers (main thread). Plain module scriptblocks.
$script:GangplankOnSessionJob = {
    param($Result,$Context)
    if ($Context.Kind -eq 'connect') {
        $script:GangplankApp.Generation++
    } elseif ($Context.Generation -ne $script:GangplankApp.Generation) {
        # The user disconnected or connected elsewhere while this ran: report the
        # result, but do not resurrect the old session.
        Write-GangplankLog -Level INFO -Message "Result of a $($Context.Kind) job for a previous session was not applied."
        return [ordered]@{ stale = $true; saved = $(if ($Result.ContainsKey('Saved')) { $Result.Saved } else { $null }) }
    }
    Set-GangplankAppSession -Snapshot $Result.Session -Token $Context.Token
    $s = $script:GangplankApp.Session
    # Explicit lower-case fields (PowerShell hashtables are case-insensitive).
    return [ordered]@{
        project = $s.ProjectPath; provider = $s.Provider
        branch = $(if ($s.LastBranch) { $s.LastBranch } else { $s.DefaultBranch })
        defaultBranch = $s.DefaultBranch; branches = @($s.Branches)
        workspace = $s.LocalPath; folder = $s.LocalPath; sha = $s.BaselineSha
        saved = $(if ($Result.ContainsKey('Saved')) { $Result.Saved } else { $null })
    }
}
$script:GangplankOnReviewJob = {
    param($Result,$Context)
    $s = $script:GangplankApp.Session
    if ($s -and $Context.Generation -eq $script:GangplankApp.Generation) {
        $s | Add-Member -MemberType NoteProperty -Name LastReviewUrl -Value $Result.Url -Force
        try { Save-GangplankSessionState -StateRoot $script:GangplankApp.StateRoot -Session $s } catch { Write-GangplankLog -Level WARN -Message 'Session state could not be saved.' }
    }
    return @{ url = $Result.Url; title = $Result.Title }
}

function Send-GangplankJobStarted {
    param([string]$Id)
    Send-GangplankJson -Status 202 -Object @{ job = $Id }
}

function Invoke-GangplankRoute {
    param($Req)
    # Requests answered on the HTTP loop must fail fast (one attempt, short
    # timeout) so a network outage cannot freeze the UI; jobs keep full retries.
    $script:GangplankHttpInteractive = $true
    try {
        Invoke-GangplankRouteCore -Req $Req
    } catch {
        $parts = Split-GangplankCodedMessage -Message $_.Exception.Message
        Write-GangplankLog -Level WARN -Message ("{0} {1} failed: {2}" -f $Req.Method, $Req.Path, $parts.Code)
        if (-not $script:GangplankHttp.Responded) { Send-GangplankError (Get-GangplankErrorStatus $parts.Code) $parts.Code $parts.Message }
    } finally {
        $script:GangplankHttpInteractive = $false
    }
}

function Invoke-GangplankRouteCore {
    param($Req)
    $m = $Req.Method; $p = $Req.Path
    $app = $script:GangplankApp

    if ($m -eq 'GET' -and $p -eq '/api/status') {
        $session = Get-GangplankLiveSession
        $snap = Get-GangplankAppSnapshot
        $creds = Get-GangplankCredentialStatus
        $ai = @($creds.credentials | Where-Object { $_.provider -eq 'AI' })[0]
        Send-GangplankJson -Object @{
            connected = ($null -ne $session)
            restoredWaiting = ($null -eq $session -and $null -ne $snap)
            provider = $(if ($snap) { $snap.Provider } else { $null })
            project = $(if ($snap) { $snap.ProjectPath } else { $null })
            branch = $(if ($snap) { $(if ($snap.LastBranch) { $snap.LastBranch } else { $snap.DefaultBranch }) } else { $null })
            defaultBranch = $(if ($snap) { $snap.DefaultBranch } else { $null })
            workspace = $(if ($snap) { $snap.LocalPath } else { $null })
            hasBaseline = [bool]($snap -and $snap.BaselineSha)
            ai = [bool]$ai.configured
            canReview = [bool]($snap -and $snap.LastSaveMessage -and -not $snap.LastReviewUrl -and $snap.LastBranch -and $snap.LastBranch -ne $snap.DefaultBranch)
            autoStop = [bool](Get-GangplankHostLifecycleState).autoStop
            localDev = [bool]$app.LocalDev
            devProvider = $(if (Get-GangplankDevProvider) { Get-GangplankDevProvider } else { '' })
        }
        return
    }

    # ---- lifecycle -----------------------------------------------------------
    if ($m -eq 'POST' -and $p -eq '/api/session/stop') {
        # End session. A deliberate second header, so no other API call can end it by mistake.
        $intent = ''; if ($Req.Headers.ContainsKey('X-Gangplank-Intent')) { $intent = $Req.Headers['X-Gangplank-Intent'] }
        if ($intent -cne 'end-session') { throw 'BAD_REQUEST|Ending the session requires the X-Gangplank-Intent header.' }
        Write-GangplankLog -Level INFO -Message 'End session requested from the browser.'
        Request-GangplankHostStop -Reason 'End session requested from the browser.'
        Send-GangplankJson -Object @{ stopping = $true; waitingForJobs = [bool](Test-GangplankJobsBusy) }
        return
    }

    # ---- background jobs ---------------------------------------------------
    if ($p -match '^/api/jobs/(job-[a-f0-9]{12})$' -and $m -eq 'GET') {
        $after = 0; [void][int]::TryParse([string](Get-GangplankQueryValue $Req.Query 'after'),[ref]$after)
        Send-GangplankJson -Object (Get-GangplankJobView -Id $Matches[1] -After $after)
        return
    }
    if ($p -match '^/api/jobs/(job-[a-f0-9]{12})/cancel$' -and $m -eq 'POST') {
        Send-GangplankJson -Object @{ cancelled = (Stop-GangplankJob -Id $Matches[1]) }
        return
    }

    # ---- credentials and Lazarette -------------------------------------------------
    if ($m -eq 'GET' -and $p -eq '/api/integrations') {
        Send-GangplankJson -Object (Get-GangplankCredentialStatus)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/settings') {
        Send-GangplankJson -Object (Get-GangplankAppSettingsView)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/settings/intelligence') {
        $view = Set-GangplankAiSettings -Endpoint ([string](Get-GangplankBodyValue $Req 'endpoint')) -Flavor ([string](Get-GangplankBodyValue $Req 'profile')) -Model ([string](Get-GangplankBodyValue $Req 'model')) -Base ([string](Get-GangplankBodyValue $Req 'base')) -Auth ([string](Get-GangplankBodyValue $Req 'auth'))
        Send-GangplankJson -Object (Get-GangplankAppSettingsView)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/ai/detect') {
        $endpoint = [string](Get-GangplankBodyValue $Req 'endpoint')
        if (-not $endpoint) { $endpoint = (Get-GangplankAiConfiguration).Endpoint }
        [void](Assert-GangplankAiEndpoint -Url $endpoint)   # refuse before any request leaves
        $jobArgs = @{ Endpoint = $endpoint; AiToken = (Get-GangplankAiToken); Current = [string](Get-GangplankBodyValue $Req 'model') }
        $id = Start-GangplankJob -Kind 'ai-detect' -Group 'ai' -Function 'Invoke-GangplankJobAiDetect' -Arguments $jobArgs
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/ai/test') {
        $id = Start-GangplankJob -Kind 'ai-test' -Group 'ai' -Function 'Invoke-GangplankJobAiTest' -Arguments @{ AiToken = (Get-GangplankAiToken) }
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/settings/workspace') {
        if ($app.WorkRootFixed) { throw 'BAD_STATE|This Gangplank was started with -WorkRoot; change the folder there.' }
        if (-not [string]::IsNullOrWhiteSpace((Get-GangplankEnv WORK_ROOT))) { throw 'BAD_STATE|The workspace folder is set by GANGPLANK_WORK_ROOT.' }
        $app.WorkRoot = Set-GangplankWorkspaceRoot -Path ([string](Get-GangplankBodyValue $Req 'root'))
        Send-GangplankJson -Object (Get-GangplankAppSettingsView)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/credentials') {
        $provider = [string](Get-GangplankBodyValue $Req 'provider')
        $token = [string](Get-GangplankBodyValue $Req 'token')
        [void](Set-GangplankStoredCredential -Provider $provider -Token $token)
        $token = $null
        Update-GangplankSessionCredential -Provider $provider
        Send-GangplankJson -Object (Get-GangplankCredentialStatus)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/credentials/remove') {
        $provider = [string](Get-GangplankBodyValue $Req 'provider')
        [void](Remove-GangplankStoredCredential -Provider $provider)
        Update-GangplankSessionCredential -Provider $provider
        Send-GangplankJson -Object (Get-GangplankCredentialStatus)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/integrations/lazarette') {
        $enabled = ((Get-GangplankBodyValue $Req 'enabled') -eq $true)
        [void](Set-GangplankLazaretteSettings -Enabled $enabled -Path ([string](Get-GangplankBodyValue $Req 'path')))
        $status = Get-GangplankCredentialStatus
        Send-GangplankJson -Object @{ status = $status; restartRequired = $true }
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/integrations/map') {
        $provider = [string](Get-GangplankBodyValue $Req 'provider')
        $item = [string](Get-GangplankBodyValue $Req 'item')
        $provider = Resolve-GangplankPurposeName $provider -Strict   # legacy purpose names still accepted
        if ($provider -notin @('GitHub','GitLab','AI')) { throw 'BAD_REQUEST|Unsupported credential provider.' }
        if (-not (Test-GangplankLazaretteConfigured)) { throw 'ARC_NOT_CONFIGURED|Enable Lazarette first.' }
        $names = @(Get-GangplankLazaretteServiceNames)
        if ($names.Count -gt 0 -and $item -notin $names) { throw 'BAD_REQUEST|Select an item that exists in the unlocked Lazarette vault.' }
        [void](Set-GangplankLazaretteItemName -Provider $provider -ServiceName $item)
        Send-GangplankJson -Object (Get-GangplankCredentialStatus)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/audit') {
        $last = 50; [void][int]::TryParse([string](Get-GangplankQueryValue $Req.Query 'last'),[ref]$last)
        if ($last -lt 1 -or $last -gt 500) { $last = 50 }
        Send-GangplankJson -Object @{ entries = @(Get-GangplankAuditEntries -Last $last) }
        return
    }

    # ---- project and workspace ----------------------------------------------
    if ($m -eq 'POST' -and $p -eq '/api/connect') {
        $url = [string](Get-GangplankBodyValue $Req 'url')
        if (-not $url -or $url.Length -gt 500) { throw 'BAD_REQUEST|Enter a valid GitHub or GitLab project URL.' }
        Assert-GangplankTrustedRepositoryUrl -Url $url
        $parsed = Parse-GangplankRepoUrl -Url $url
        $token = (Resolve-GangplankCredential -Provider $parsed.Provider).Value
        $id = Start-GangplankJob -Kind 'connect' -Group 'workspace' -Function 'Invoke-GangplankJobConnect' -Arguments @{ Url = $url; Token = $token; DevGitHubUrl = (Get-GangplankDevProvider) } -OnComplete $script:GangplankOnSessionJob -Context (Get-GangplankJobContext -Token $token -Kind 'connect')
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/disconnect') {
        $script:GangplankApp.Generation++
        Set-GangplankAppSession -Snapshot $null
        Send-GangplankJson -Object @{ connected = $false }
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/start') {
        $session = Get-GangplankLiveSession -Required
        $name = [string](Get-GangplankBodyValue $Req 'name')
        if ($name) { $name = ConvertTo-GangplankBranchName -Name $name }   # validate before starting a job
        $args2 = Get-GangplankJobArguments $session
        $args2.Name = $name
        $id = Start-GangplankJob -Kind 'start' -Group 'workspace' -Function 'Invoke-GangplankJobStart' -Arguments $args2 -OnComplete $script:GangplankOnSessionJob -Context (Get-GangplankJobContext -Token $args2.Token -Kind 'start')
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/download') {
        $session = Get-GangplankLiveSession -Required
        $branch = [string](Get-GangplankBodyValue $Req 'branch')
        if ($branch.Length -gt 200 -or $branch -match '[\x00-\x1f]') { throw 'BAD_REQUEST|Branch name is not valid.' }
        $args2 = Get-GangplankJobArguments $session
        $args2.Branch = $branch
        $id = Start-GangplankJob -Kind 'download' -Group 'workspace' -Function 'Invoke-GangplankJobDownload' -Arguments $args2 -OnComplete $script:GangplankOnSessionJob -Context (Get-GangplankJobContext -Token $args2.Token -Kind 'download')
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/preview') {
        $session = Get-GangplankLiveSession
        if (-not $session -or -not $session.BaselineSha) {
            Send-GangplankJson -Object @{ ready = $false; changes = @(); remoteChanged = $false }
            return
        }
        $preview = Get-GangplankWorkspacePreview -Session $session
        Send-GangplankJson -Object @{
            ready = $true; changes = @($preview.Changes); remoteChanged = $preview.RemoteChanged
            branch = $preview.Branch; message = $preview.SmartMessage.Title; workspace = $preview.LocalPath
        }
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/save') {
        $session = Get-GangplankLiveSession -Required
        $paths = @([string[]]@(Get-GangplankBodyValue $Req 'paths') | Where-Object { $_ })
        if ($paths.Count -eq 0) { throw 'BAD_REQUEST|Select at least one file to save.' }
        if ($paths.Count -gt 1000) { throw 'BAD_REQUEST|Too many files in one save.' }
        $args2 = Get-GangplankJobArguments $session
        $args2.Paths = $paths
        $args2.Message = [string](Get-GangplankBodyValue $Req 'message')
        $args2.PublicConfirmed = ((Get-GangplankBodyValue $Req 'publicConfirmed') -eq $true)
        $id = Start-GangplankJob -Kind 'save' -Group 'workspace' -Function 'Invoke-GangplankJobSave' -Arguments $args2 -OnComplete $script:GangplankOnSessionJob -Context (Get-GangplankJobContext -Token $args2.Token -Kind 'save')
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/review') {
        $session = Get-GangplankLiveSession -Required
        if (-not $session.LastBranch) { throw 'BAD_STATE|Start a work branch before requesting review.' }
        if ($session.LastBranch -eq $session.DefaultBranch) { throw 'BAD_STATE|Cannot review the default branch against itself.' }
        if (-not $session.LastSaveMessage) { throw 'BAD_STATE|Save your changes before requesting review.' }
        if ($session.LastReviewUrl) { Send-GangplankJson -Object @{ url = $session.LastReviewUrl; title = 'Review already created'; existing = $true }; return }
        $args2 = Get-GangplankJobArguments $session
        $id = Start-GangplankJob -Kind 'review' -Group 'workspace' -Function 'Invoke-GangplankJobReview' -Arguments $args2 -OnComplete $script:GangplankOnReviewJob -Context (Get-GangplankJobContext -Token $args2.Token -Kind 'review')
        Send-GangplankJobStarted $id
        return
    }

    # ---- read-only repository views (quick, synchronous) ---------------------
    if ($m -eq 'GET' -and $p -eq '/api/branches') {
        $session = Get-GangplankLiveSession -Required
        Send-GangplankJson -Object @{ branches = @(Get-GangplankRepositoryBranches -Session $session); defaultBranch = $session.DefaultBranch }
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/history') {
        $session = Get-GangplankLiveSession -Required
        $branch = [string](Get-GangplankQueryValue $Req.Query 'branch')
        Send-GangplankJson -Object @{ commits = @(Get-GangplankRepositoryHistory -Session $session -Branch $branch); branch = $branch }
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/compare') {
        $session = Get-GangplankLiveSession -Required
        $base = [string](Get-GangplankQueryValue $Req.Query 'base'); $head = [string](Get-GangplankQueryValue $Req.Query 'head')
        if (-not $base -or -not $head) { throw 'BAD_REQUEST|Choose two branches to compare.' }
        Send-GangplankJson -Object (Get-GangplankRepositoryComparison -Session $session -Base $base -Head $head)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/reviews') {
        $session = Get-GangplankLiveSession -Required
        Send-GangplankJson -Object @{ reviews = @(Get-GangplankRepositoryReviews -Session $session) }
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/insights') {
        $session = Get-GangplankLiveSession -Required
        Send-GangplankJson -Object (Get-GangplankRepositoryInsights -Session $session)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/sentinel') {
        $session = Get-GangplankLiveSession -Required
        $destination = Get-GangplankSentinelDestination -Session $session
        $findings = @()
        if ($session.LocalPath -and $session.BaselineSha) {
            $preview = Get-GangplankWorkspacePreview -Session $session
            $paths = @($preview.Changes | Where-Object { $_.Kind -ne 'Deleted' } | ForEach-Object Path)
            if ($paths.Count -gt 0) { $findings = @((Test-GangplankSentinelPublication -Session $session -Paths $paths).Findings) }
        }
        Send-GangplankJson -Object @{ destination = $destination; findings = $findings; publicPublishingEnabled = ((Get-GangplankEnv ALLOW_PUBLIC_PUBLISH) -eq '1') }
        return
    }

    # ---- AI (advisory only) ----------------------------------------------------
    if ($m -eq 'POST' -and $p -eq '/api/commit-message') {
        $session = Get-GangplankLiveSession -Required
        $preview = Get-GangplankWorkspacePreview -Session $session
        $selected = @([string[]]@(Get-GangplankBodyValue $Req 'paths') | Where-Object { $_ })
        $known = @($preview.Changes | Where-Object { -not $_.Blocked } | ForEach-Object Path)
        foreach ($sel in $selected) { if ($sel -cnotin $known) { throw 'BAD_REQUEST|Invalid selected file.' } }
        if ($selected.Count -eq 0) { throw 'BAD_REQUEST|Select changed files first.' }
        $ai = Get-GangplankAiToken
        if (-not $ai -and (Get-GangplankAiConfiguration).Profile -ne 'ollama') { throw 'AI_NOT_CONFIGURED|AI is not connected. Add an AI token in Credentials.' }
        $kinds = @{}; foreach ($c in @($preview.Changes)) { $kinds[$c.Path] = $c.Kind }
        $jobArgs = @{
            New = @($selected | Where-Object { $kinds[$_] -eq 'New' })
            Modified = @($selected | Where-Object { $kinds[$_] -eq 'Modified' })
            Deleted = @($selected | Where-Object { $kinds[$_] -eq 'Deleted' })
            AiToken = $ai
        }
        $id = Start-GangplankJob -Kind 'commit-title' -Group 'ai' -Function 'Invoke-GangplankJobCommitTitle' -Arguments $jobArgs
        Send-GangplankJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/chat') {
        $question = [string](Get-GangplankBodyValue $Req 'message')
        if ([string]::IsNullOrWhiteSpace($question)) { throw 'BAD_REQUEST|Enter a message.' }
        if ($question.Length -gt 6000) { throw 'BAD_REQUEST|AI message exceeds 6,000 characters.' }
        $ai = Get-GangplankAiToken
        if (-not $ai -and (Get-GangplankAiConfiguration).Profile -ne 'ollama') { throw 'AI_NOT_CONFIGURED|AI is not connected. Add an AI token in Credentials.' }
        $snap = Get-GangplankAppSnapshot
        $jobArgs = @{ Question = $question; AiToken = $ai; Project = $(if ($snap) { $snap.ProjectPath } else { '' }); Branch = $(if ($snap) { $(if ($snap.LastBranch) { $snap.LastBranch } else { $snap.DefaultBranch }) } else { '' }) }
        $id = Start-GangplankJob -Kind 'chat' -Group 'chat' -Function 'Invoke-GangplankJobChat' -Arguments $jobArgs
        Send-GangplankJobStarted $id
        return
    }

    Send-GangplankError 404 'NOT_FOUND' 'Route not found.'
}
