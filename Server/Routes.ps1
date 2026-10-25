#Requires -Version 5.1
# =============================================================================
# Keystone API routes. Only reached through Invoke-KeystoneServerRequest, after
# the loopback, client-header and session-cookie checks. Long operations start
# a background job and answer 202 { job }; the UI polls /api/jobs/{id}.
# Errors are { error: CODE, message } with a safe one-line message.
# =============================================================================

$script:KeystoneApp = @{
    Session = $null        # live session (with provider object) or $null
    Restored = $null       # snapshot from a previous run, waiting for a token
    WorkRoot = ''
    WorkRootFixed = $false
    StateRoot = ''
    LocalDev = $false
    Generation = 0         # bumped on connect/disconnect; stale job results are dropped
}

function Initialize-KeystoneApp {
    # WorkRoot: where workspaces go. StateRoot: Keystone's own data (saved session).
    # LegacyStateRoot: the old <tool>\work\.keystone, read once if nothing newer exists.
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$StateRoot,[string]$LegacyStateRoot,[switch]$WorkRootFixed,[switch]$LocalDev)
    $script:KeystoneApp.WorkRoot = $WorkRoot
    $script:KeystoneApp.WorkRootFixed = [bool]$WorkRootFixed
    $script:KeystoneApp.StateRoot = $StateRoot
    $script:KeystoneApp.LocalDev = [bool]$LocalDev
    $script:KeystoneApp.Session = $null
    $script:KeystoneApp.Restored = Read-KeystoneSessionState -StateRoot $StateRoot
    if (-not $script:KeystoneApp.Restored -and $LegacyStateRoot -and (Test-Path -LiteralPath (Get-KeystoneSessionStatePath -StateRoot $LegacyStateRoot))) {
        $script:KeystoneApp.Restored = Read-KeystoneSessionState -StateRoot $LegacyStateRoot
        if ($script:KeystoneApp.Restored) {
            Write-KeystoneLog -Level INFO -Message 'Picked up the session saved by an earlier Keystone (work\.keystone). New workspaces now go to the workspace folder.'
            try { Save-KeystoneSessionState -StateRoot $StateRoot -Session ([pscustomobject]$script:KeystoneApp.Restored) } catch { }
        }
    }
    if ($script:KeystoneApp.Restored) {
        Write-KeystoneLog -Level INFO -Message "Restored session for $($script:KeystoneApp.Restored.ProjectPath) (branch $($script:KeystoneApp.Restored.LastBranch))."
    }
}

function Get-KeystoneAppSnapshot {
    if ($script:KeystoneApp.Session) { return (ConvertTo-KeystoneSessionSnapshot $script:KeystoneApp.Session) }
    return $script:KeystoneApp.Restored
}

function Get-KeystoneLiveSession {
    # The live session, rebuilding a restored one once a credential is available.
    param([switch]$Required)
    if (-not $script:KeystoneApp.Session -and $script:KeystoneApp.Restored) {
        try {
            $token = (Resolve-KeystoneCredential -Provider $script:KeystoneApp.Restored.Provider).Value
            $script:KeystoneApp.Session = New-KeystoneSessionFromSnapshot -Snapshot $script:KeystoneApp.Restored -Token $token
            $script:KeystoneApp.Restored = $null
        } catch {
            if ($Required) { throw }
        }
    }
    if ($Required -and -not $script:KeystoneApp.Session) { throw 'NOT_CONNECTED|Connect a project first.' }
    return $script:KeystoneApp.Session
}

function Set-KeystoneAppSession {
    param($Snapshot,[string]$Token)
    if (-not $Snapshot) {
        $script:KeystoneApp.Session = $null
        $script:KeystoneApp.Restored = $null
    } else {
        if (-not $Token) { $Token = (Resolve-KeystoneCredential -Provider $Snapshot.Provider).Value }
        $script:KeystoneApp.Session = New-KeystoneSessionFromSnapshot -Snapshot $Snapshot -Token $Token
        $script:KeystoneApp.Restored = $null
    }
    # Saving state is best effort (antivirus, sync clients): never fail the request for it.
    try { Save-KeystoneSessionState -StateRoot $script:KeystoneApp.StateRoot -Session $script:KeystoneApp.Session }
    catch { Write-KeystoneLog -Level WARN -Message "Session state could not be saved: $($_.Exception.Message)" }
}

function Update-KeystoneSessionCredential {
    # After a token is saved or removed, rebuild the live provider so quick reads use it.
    param([string]$Provider)
    $s = $script:KeystoneApp.Session
    if (-not $s -or $s.Provider -ne $Provider) { return }
    try {
        $token = (Resolve-KeystoneCredential -Provider $Provider).Value
        $script:KeystoneApp.Session = New-KeystoneSessionFromSnapshot -Snapshot (ConvertTo-KeystoneSessionSnapshot $s) -Token $token
    } catch {
        # No credential any more: keep the work as a restorable snapshot.
        $script:KeystoneApp.Restored = ConvertTo-KeystoneSessionSnapshot $s
        $script:KeystoneApp.Session = $null
    }
}

function Get-KeystoneAppSettingsView {
    return [ordered]@{
        workspaces = [ordered]@{
            root = $script:KeystoneApp.WorkRoot
            default = (Get-KeystoneDefaultWorkspaceRoot)
            fixed = [bool]($script:KeystoneApp.WorkRootFixed -or -not [string]::IsNullOrWhiteSpace($env:KEYSTONE_WORK_ROOT))
        }
        intelligence = (Get-KeystoneAiSettingsView)
    }
}

function Get-KeystoneErrorStatus {
    param([string]$Code)
    switch -Regex ($Code) {
        '^(BAD_REQUEST|INVALID)' { return 400 }
        '^(NOT_FOUND)$' { return 404 }
        '^(BUSY|CONFLICT|NOT_CONNECTED|BAD_STATE|CREDENTIAL_MISSING|CREDENTIAL_STORE_UNAVAILABLE|ARC_[A-Z_]+|AI_NOT_CONFIGURED|GIT_[A-Z_]+)$' { return 409 }
        '^(AUTH_REJECTED|FORBIDDEN|RATE_LIMITED|SERVER_ERROR|NETWORK)$' { return 502 }
        default { return 400 }
    }
}

function Split-KeystoneCodedMessage {
    param([string]$Message)
    $safe = Get-KeystoneSafeErrorMessage -Message $Message
    if ($safe -match '^([A-Z][A-Z0-9_]{2,40})\|(.*)$') { return @{ Code = $Matches[1]; Message = $Matches[2].Trim() } }
    return @{ Code = 'FAILED'; Message = $safe }
}

function Get-KeystoneBodyValue {
    param($Req,[string]$Name)
    if ($null -eq $Req.Json) { return $null }
    $p = $Req.Json.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-KeystoneJobContext {
    # Main-thread context for a workspace job: which session generation it belongs
    # to, and the token to reuse when its result is applied.
    param([string]$Token,[string]$Kind)
    return @{ Generation = $script:KeystoneApp.Generation; Token = $Token; Kind = $Kind }
}

function Get-KeystoneJobArguments {
    # Snapshot + token for workspace jobs; the token never leaves this process.
    param([Parameter(Mandatory)]$Session)
    return @{
        Session = (ConvertTo-KeystoneSessionSnapshot $Session)
        Token = (Resolve-KeystoneCredential -Provider $Session.Provider).Value
        WorkRoot = $script:KeystoneApp.WorkRoot
        DevGitHubUrl = (Get-KeystoneDevProvider)
    }
}

# Job completion handlers (main thread). Plain module scriptblocks.
$script:KeystoneOnSessionJob = {
    param($Result,$Context)
    if ($Context.Kind -eq 'connect') {
        $script:KeystoneApp.Generation++
    } elseif ($Context.Generation -ne $script:KeystoneApp.Generation) {
        # The user disconnected or connected elsewhere while this ran: report the
        # result, but do not resurrect the old session.
        Write-KeystoneLog -Level INFO -Message "Result of a $($Context.Kind) job for a previous session was not applied."
        return [ordered]@{ stale = $true; saved = $(if ($Result.ContainsKey('Saved')) { $Result.Saved } else { $null }) }
    }
    Set-KeystoneAppSession -Snapshot $Result.Session -Token $Context.Token
    $s = $script:KeystoneApp.Session
    # Explicit lower-case fields (PowerShell hashtables are case-insensitive).
    return [ordered]@{
        project = $s.ProjectPath; provider = $s.Provider
        branch = $(if ($s.LastBranch) { $s.LastBranch } else { $s.DefaultBranch })
        defaultBranch = $s.DefaultBranch; branches = @($s.Branches)
        workspace = $s.LocalPath; folder = $s.LocalPath; sha = $s.BaselineSha
        saved = $(if ($Result.ContainsKey('Saved')) { $Result.Saved } else { $null })
    }
}
$script:KeystoneOnReviewJob = {
    param($Result,$Context)
    $s = $script:KeystoneApp.Session
    if ($s -and $Context.Generation -eq $script:KeystoneApp.Generation) {
        $s | Add-Member -MemberType NoteProperty -Name LastReviewUrl -Value $Result.Url -Force
        try { Save-KeystoneSessionState -StateRoot $script:KeystoneApp.StateRoot -Session $s } catch { Write-KeystoneLog -Level WARN -Message 'Session state could not be saved.' }
    }
    return @{ url = $Result.Url; title = $Result.Title }
}

function Send-KeystoneJobStarted {
    param([string]$Id)
    Send-KeystoneJson -Status 202 -Object @{ job = $Id }
}

function Invoke-KeystoneRoute {
    param($Req)
    # Requests answered on the HTTP loop must fail fast (one attempt, short
    # timeout) so a network outage cannot freeze the UI; jobs keep full retries.
    $script:KeystoneHttpInteractive = $true
    try {
        Invoke-KeystoneRouteCore -Req $Req
    } catch {
        $parts = Split-KeystoneCodedMessage -Message $_.Exception.Message
        Write-KeystoneLog -Level WARN -Message ("{0} {1} failed: {2}" -f $Req.Method, $Req.Path, $parts.Code)
        if (-not $script:KeystoneHttp.Responded) { Send-KeystoneError (Get-KeystoneErrorStatus $parts.Code) $parts.Code $parts.Message }
    } finally {
        $script:KeystoneHttpInteractive = $false
    }
}

function Invoke-KeystoneRouteCore {
    param($Req)
    $m = $Req.Method; $p = $Req.Path
    $app = $script:KeystoneApp

    if ($m -eq 'GET' -and $p -eq '/api/status') {
        $session = Get-KeystoneLiveSession
        $snap = Get-KeystoneAppSnapshot
        $creds = Get-KeystoneCredentialStatus
        $ai = @($creds.credentials | Where-Object { $_.provider -eq 'GenAi' })[0]
        Send-KeystoneJson -Object @{
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
            localDev = [bool]$app.LocalDev
            devProvider = $(if (Get-KeystoneDevProvider) { Get-KeystoneDevProvider } else { '' })
        }
        return
    }

    # ---- background jobs ---------------------------------------------------
    if ($p -match '^/api/jobs/(job-[a-f0-9]{12})$' -and $m -eq 'GET') {
        $after = 0; [void][int]::TryParse([string](Get-KeystoneQueryValue $Req.Query 'after'),[ref]$after)
        Send-KeystoneJson -Object (Get-KeystoneJobView -Id $Matches[1] -After $after)
        return
    }
    if ($p -match '^/api/jobs/(job-[a-f0-9]{12})/cancel$' -and $m -eq 'POST') {
        Send-KeystoneJson -Object @{ cancelled = (Stop-KeystoneJob -Id $Matches[1]) }
        return
    }

    # ---- credentials and ARC -------------------------------------------------
    if ($m -eq 'GET' -and $p -eq '/api/integrations') {
        Send-KeystoneJson -Object (Get-KeystoneCredentialStatus)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/settings') {
        Send-KeystoneJson -Object (Get-KeystoneAppSettingsView)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/settings/intelligence') {
        $view = Set-KeystoneAiSettings -Endpoint ([string](Get-KeystoneBodyValue $Req 'endpoint')) -Flavor ([string](Get-KeystoneBodyValue $Req 'profile')) -Model ([string](Get-KeystoneBodyValue $Req 'model')) -Base ([string](Get-KeystoneBodyValue $Req 'base')) -Auth ([string](Get-KeystoneBodyValue $Req 'auth'))
        Send-KeystoneJson -Object (Get-KeystoneAppSettingsView)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/ai/detect') {
        $endpoint = [string](Get-KeystoneBodyValue $Req 'endpoint')
        if (-not $endpoint) { $endpoint = (Get-KeystoneAiConfiguration).Endpoint }
        [void](Assert-KeystoneAiEndpoint -Url $endpoint)   # refuse before any request leaves
        $jobArgs = @{ Endpoint = $endpoint; AiToken = (Get-KeystoneAiToken); Current = [string](Get-KeystoneBodyValue $Req 'model') }
        $id = Start-KeystoneJob -Kind 'ai-detect' -Group 'ai' -Function 'Invoke-KeystoneJobAiDetect' -Arguments $jobArgs
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/ai/test') {
        $id = Start-KeystoneJob -Kind 'ai-test' -Group 'ai' -Function 'Invoke-KeystoneJobAiTest' -Arguments @{ AiToken = (Get-KeystoneAiToken) }
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/settings/workspace') {
        if ($app.WorkRootFixed) { throw 'BAD_STATE|This Keystone was started with -WorkRoot; change the folder there.' }
        if (-not [string]::IsNullOrWhiteSpace($env:KEYSTONE_WORK_ROOT)) { throw 'BAD_STATE|The workspace folder is set by KEYSTONE_WORK_ROOT.' }
        $app.WorkRoot = Set-KeystoneWorkspaceRoot -Path ([string](Get-KeystoneBodyValue $Req 'root'))
        Send-KeystoneJson -Object (Get-KeystoneAppSettingsView)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/credentials') {
        $provider = [string](Get-KeystoneBodyValue $Req 'provider')
        $token = [string](Get-KeystoneBodyValue $Req 'token')
        [void](Set-KeystoneStoredCredential -Provider $provider -Token $token)
        $token = $null
        Update-KeystoneSessionCredential -Provider $provider
        Send-KeystoneJson -Object (Get-KeystoneCredentialStatus)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/credentials/remove') {
        $provider = [string](Get-KeystoneBodyValue $Req 'provider')
        [void](Remove-KeystoneStoredCredential -Provider $provider)
        Update-KeystoneSessionCredential -Provider $provider
        Send-KeystoneJson -Object (Get-KeystoneCredentialStatus)
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/integrations/arc') {
        $enabled = ((Get-KeystoneBodyValue $Req 'enabled') -eq $true)
        [void](Set-KeystoneArcSettings -Enabled $enabled -Path ([string](Get-KeystoneBodyValue $Req 'path')))
        $status = Get-KeystoneCredentialStatus
        Send-KeystoneJson -Object @{ status = $status; restartRequired = $true }
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/integrations/map') {
        $provider = [string](Get-KeystoneBodyValue $Req 'provider')
        $item = [string](Get-KeystoneBodyValue $Req 'item')
        if ($provider -notin @('GitHub','GitLab','GenAi')) { throw 'BAD_REQUEST|Unsupported credential provider.' }
        if (-not (Test-KeystoneArcConfigured)) { throw 'ARC_NOT_CONFIGURED|Enable ARC first.' }
        $names = @(Get-KeystoneArcServiceNames)
        if ($names.Count -gt 0 -and $item -notin $names) { throw 'BAD_REQUEST|Select an item that exists in the unlocked ARC vault.' }
        [void](Set-KeystoneArcItemName -Provider $provider -ServiceName $item)
        Send-KeystoneJson -Object (Get-KeystoneCredentialStatus)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/audit') {
        $last = 50; [void][int]::TryParse([string](Get-KeystoneQueryValue $Req.Query 'last'),[ref]$last)
        if ($last -lt 1 -or $last -gt 500) { $last = 50 }
        Send-KeystoneJson -Object @{ entries = @(Get-KeystoneAuditEntries -Last $last) }
        return
    }

    # ---- project and workspace ----------------------------------------------
    if ($m -eq 'POST' -and $p -eq '/api/connect') {
        $url = [string](Get-KeystoneBodyValue $Req 'url')
        if (-not $url -or $url.Length -gt 500) { throw 'BAD_REQUEST|Enter a valid GitHub or GitLab project URL.' }
        Assert-KeystoneTrustedRepositoryUrl -Url $url
        $parsed = Parse-KeystoneRepoUrl -Url $url
        $token = (Resolve-KeystoneCredential -Provider $parsed.Provider).Value
        $id = Start-KeystoneJob -Kind 'connect' -Group 'workspace' -Function 'Invoke-KeystoneJobConnect' -Arguments @{ Url = $url; Token = $token; DevGitHubUrl = (Get-KeystoneDevProvider) } -OnComplete $script:KeystoneOnSessionJob -Context (Get-KeystoneJobContext -Token $token -Kind 'connect')
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/disconnect') {
        $script:KeystoneApp.Generation++
        Set-KeystoneAppSession -Snapshot $null
        Send-KeystoneJson -Object @{ connected = $false }
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/start') {
        $session = Get-KeystoneLiveSession -Required
        $name = [string](Get-KeystoneBodyValue $Req 'name')
        if ($name) { $name = ConvertTo-KeystoneBranchName -Name $name }   # validate before starting a job
        $args2 = Get-KeystoneJobArguments $session
        $args2.Name = $name
        $id = Start-KeystoneJob -Kind 'start' -Group 'workspace' -Function 'Invoke-KeystoneJobStart' -Arguments $args2 -OnComplete $script:KeystoneOnSessionJob -Context (Get-KeystoneJobContext -Token $args2.Token -Kind 'start')
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/download') {
        $session = Get-KeystoneLiveSession -Required
        $branch = [string](Get-KeystoneBodyValue $Req 'branch')
        if ($branch.Length -gt 200 -or $branch -match '[\x00-\x1f]') { throw 'BAD_REQUEST|Branch name is not valid.' }
        $args2 = Get-KeystoneJobArguments $session
        $args2.Branch = $branch
        $id = Start-KeystoneJob -Kind 'download' -Group 'workspace' -Function 'Invoke-KeystoneJobDownload' -Arguments $args2 -OnComplete $script:KeystoneOnSessionJob -Context (Get-KeystoneJobContext -Token $args2.Token -Kind 'download')
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/preview') {
        $session = Get-KeystoneLiveSession
        if (-not $session -or -not $session.BaselineSha) {
            Send-KeystoneJson -Object @{ ready = $false; changes = @(); remoteChanged = $false }
            return
        }
        $preview = Get-KeystoneWorkspacePreview -Session $session
        Send-KeystoneJson -Object @{
            ready = $true; changes = @($preview.Changes); remoteChanged = $preview.RemoteChanged
            branch = $preview.Branch; message = $preview.SmartMessage.Title; workspace = $preview.LocalPath
        }
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/save') {
        $session = Get-KeystoneLiveSession -Required
        $paths = @([string[]]@(Get-KeystoneBodyValue $Req 'paths') | Where-Object { $_ })
        if ($paths.Count -eq 0) { throw 'BAD_REQUEST|Select at least one file to save.' }
        if ($paths.Count -gt 1000) { throw 'BAD_REQUEST|Too many files in one save.' }
        $args2 = Get-KeystoneJobArguments $session
        $args2.Paths = $paths
        $args2.Message = [string](Get-KeystoneBodyValue $Req 'message')
        $args2.PublicConfirmed = ((Get-KeystoneBodyValue $Req 'publicConfirmed') -eq $true)
        $id = Start-KeystoneJob -Kind 'save' -Group 'workspace' -Function 'Invoke-KeystoneJobSave' -Arguments $args2 -OnComplete $script:KeystoneOnSessionJob -Context (Get-KeystoneJobContext -Token $args2.Token -Kind 'save')
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/review') {
        $session = Get-KeystoneLiveSession -Required
        if (-not $session.LastBranch) { throw 'BAD_STATE|Start a work branch before requesting review.' }
        if ($session.LastBranch -eq $session.DefaultBranch) { throw 'BAD_STATE|Cannot review the default branch against itself.' }
        if (-not $session.LastSaveMessage) { throw 'BAD_STATE|Save your changes before requesting review.' }
        if ($session.LastReviewUrl) { Send-KeystoneJson -Object @{ url = $session.LastReviewUrl; title = 'Review already created'; existing = $true }; return }
        $args2 = Get-KeystoneJobArguments $session
        $id = Start-KeystoneJob -Kind 'review' -Group 'workspace' -Function 'Invoke-KeystoneJobReview' -Arguments $args2 -OnComplete $script:KeystoneOnReviewJob -Context (Get-KeystoneJobContext -Token $args2.Token -Kind 'review')
        Send-KeystoneJobStarted $id
        return
    }

    # ---- read-only repository views (quick, synchronous) ---------------------
    if ($m -eq 'GET' -and $p -eq '/api/branches') {
        $session = Get-KeystoneLiveSession -Required
        Send-KeystoneJson -Object @{ branches = @(Get-KeystoneRepositoryBranches -Session $session); defaultBranch = $session.DefaultBranch }
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/history') {
        $session = Get-KeystoneLiveSession -Required
        $branch = [string](Get-KeystoneQueryValue $Req.Query 'branch')
        Send-KeystoneJson -Object @{ commits = @(Get-KeystoneRepositoryHistory -Session $session -Branch $branch); branch = $branch }
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/compare') {
        $session = Get-KeystoneLiveSession -Required
        $base = [string](Get-KeystoneQueryValue $Req.Query 'base'); $head = [string](Get-KeystoneQueryValue $Req.Query 'head')
        if (-not $base -or -not $head) { throw 'BAD_REQUEST|Choose two branches to compare.' }
        Send-KeystoneJson -Object (Get-KeystoneRepositoryComparison -Session $session -Base $base -Head $head)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/reviews') {
        $session = Get-KeystoneLiveSession -Required
        Send-KeystoneJson -Object @{ reviews = @(Get-KeystoneRepositoryReviews -Session $session) }
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/insights') {
        $session = Get-KeystoneLiveSession -Required
        Send-KeystoneJson -Object (Get-KeystoneRepositoryInsights -Session $session)
        return
    }
    if ($m -eq 'GET' -and $p -eq '/api/sentinel') {
        $session = Get-KeystoneLiveSession -Required
        $destination = Get-KeystoneSentinelDestination -Session $session
        $findings = @()
        if ($session.LocalPath -and $session.BaselineSha) {
            $preview = Get-KeystoneWorkspacePreview -Session $session
            $paths = @($preview.Changes | Where-Object { $_.Kind -ne 'Deleted' } | ForEach-Object Path)
            if ($paths.Count -gt 0) { $findings = @((Test-KeystoneSentinelPublication -Session $session -Paths $paths).Findings) }
        }
        Send-KeystoneJson -Object @{ destination = $destination; findings = $findings; publicPublishingEnabled = ($env:KEYSTONE_ALLOW_PUBLIC_PUBLISH -eq '1') }
        return
    }

    # ---- AI (advisory only) ----------------------------------------------------
    if ($m -eq 'POST' -and $p -eq '/api/commit-message') {
        $session = Get-KeystoneLiveSession -Required
        $preview = Get-KeystoneWorkspacePreview -Session $session
        $selected = @([string[]]@(Get-KeystoneBodyValue $Req 'paths') | Where-Object { $_ })
        $known = @($preview.Changes | Where-Object { -not $_.Blocked } | ForEach-Object Path)
        foreach ($sel in $selected) { if ($sel -cnotin $known) { throw 'BAD_REQUEST|Invalid selected file.' } }
        if ($selected.Count -eq 0) { throw 'BAD_REQUEST|Select changed files first.' }
        $ai = Get-KeystoneAiToken
        if (-not $ai -and (Get-KeystoneAiConfiguration).Profile -ne 'ollama') { throw 'AI_NOT_CONFIGURED|AI is not connected. Add a GenAI token in Credentials.' }
        $kinds = @{}; foreach ($c in @($preview.Changes)) { $kinds[$c.Path] = $c.Kind }
        $jobArgs = @{
            New = @($selected | Where-Object { $kinds[$_] -eq 'New' })
            Modified = @($selected | Where-Object { $kinds[$_] -eq 'Modified' })
            Deleted = @($selected | Where-Object { $kinds[$_] -eq 'Deleted' })
            AiToken = $ai
        }
        $id = Start-KeystoneJob -Kind 'commit-title' -Group 'ai' -Function 'Invoke-KeystoneJobCommitTitle' -Arguments $jobArgs
        Send-KeystoneJobStarted $id
        return
    }
    if ($m -eq 'POST' -and $p -eq '/api/chat') {
        $question = [string](Get-KeystoneBodyValue $Req 'message')
        if ([string]::IsNullOrWhiteSpace($question)) { throw 'BAD_REQUEST|Enter a message.' }
        if ($question.Length -gt 6000) { throw 'BAD_REQUEST|AI message exceeds 6,000 characters.' }
        $ai = Get-KeystoneAiToken
        if (-not $ai -and (Get-KeystoneAiConfiguration).Profile -ne 'ollama') { throw 'AI_NOT_CONFIGURED|AI is not connected. Add a GenAI token in Credentials.' }
        $snap = Get-KeystoneAppSnapshot
        $jobArgs = @{ Question = $question; AiToken = $ai; Project = $(if ($snap) { $snap.ProjectPath } else { '' }); Branch = $(if ($snap) { $(if ($snap.LastBranch) { $snap.LastBranch } else { $snap.DefaultBranch }) } else { '' }) }
        $id = Start-KeystoneJob -Kind 'chat' -Group 'chat' -Function 'Invoke-KeystoneJobChat' -Arguments $jobArgs
        Send-KeystoneJobStarted $id
        return
    }

    Send-KeystoneError 404 'NOT_FOUND' 'Route not found.'
}
