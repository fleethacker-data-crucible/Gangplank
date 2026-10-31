#Requires -Version 5.1
# ============================================================
#  Core/Reviews.ps1 - reviews end to end (roadmap 13)
#  Open one review request (GitHub pull request / GitLab merge request) and see
#  its status, checks, conversation and changed files; reply with a comment;
#  merge it when the provider allows it.
#
#  Rules:
#   * Every call goes through the provider's InvokeApi; the token never leaves it.
#   * The review must be one of the open reviews the project lists (no guessing numbers).
#   * Merge is never forced: it needs the explicit confirm flag, the head sha the
#     user saw (a branch that moved since is refused as CONFLICT), a review the
#     provider reports as mergeable, and the provider's own sha guard on the PUT.
#     The source branch is never deleted.
#   * Comments are plain text, bounded, and shown in the browser with textContent.
#   * Every comment and merge (and every refused merge) writes an audit entry
#     (Core/Audit.ps1): who/what/where, never the comment text or a token.
#   * Provider text reaches the browser only through bounded, single-line fields.
# ============================================================

$script:GangplankReviewCommentMax = 4000
$script:GangplankReviewTextMax = 4000
$script:GangplankReviewDescriptionMax = 2000

function ConvertTo-GangplankReviewNumber {
    # Review numbers are positive integers (GitHub number / GitLab iid).
    [CmdletBinding()]
    param($Number)
    $text = ([string]$Number).Trim()
    if ($text -notmatch '^[0-9]{1,9}$' -or [int]$text -lt 1) { throw 'BAD_REQUEST|The review number is not valid.' }
    return [int]$text
}

function ConvertTo-GangplankReviewText {
    # Bounded display text from the provider: control characters removed.
    param($Value,[int]$Max = 0)
    if ($Max -le 0) { $Max = $script:GangplankReviewTextMax }
    $s = [string]$Value
    $s = $s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
    if ($s.Length -gt $Max) { $s = $s.Substring(0,$Max) + '...' }
    return $s
}

function ConvertTo-GangplankReviewCommentText {
    # The text a user may post: plain text, 1..4000 characters, no control characters.
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'BAD_REQUEST|Write a comment first.' }
    $t = ($Text -replace "`r`n","`n" -replace "`r","`n").Trim()
    if ($t -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') { throw 'BAD_REQUEST|Comments are plain text. Remove the special control characters.' }
    if ($t.Length -gt $script:GangplankReviewCommentMax) {
        throw ('BAD_REQUEST|Comments are limited to {0:N0} characters. This one has {1:N0}.' -f $script:GangplankReviewCommentMax,$t.Length)
    }
    return $t
}

function Assert-GangplankReviewProvider {
    param([Parameter(Mandatory)]$Session)
    if (-not $Session -or -not $Session.ProviderObj) { throw 'NOT_CONNECTED|Connect a project first.' }
    if ($Session.Provider -notin @('GitHub','GitLab')) { throw 'Unsupported repository provider.' }
}

function Assert-GangplankOpenReview {
    # The review must be one the project lists as open. Returns the list row.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Number)
    Assert-GangplankReviewProvider -Session $Session
    $n = ConvertTo-GangplankReviewNumber $Number
    $row = @(Get-GangplankRepositoryReviews -Session $Session | Where-Object { [int]$_.Number -eq $n })
    if ($row.Count -eq 0) { throw 'NOT_FOUND|That review request is not open in this project. Refresh the list and try again.' }
    return $row[0]
}

function Get-GangplankReviewCore {
    # One review, normalised across providers (no checks, comments or files).
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][int]$Number)
    $provider = $Session.ProviderObj
    if ($Session.Provider -eq 'GitHub') {
        $pr = $provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/pulls/$Number")
        if (-not $pr -or -not $pr.number) { throw 'NOT_FOUND|That review request was not found.' }
        $state = if ($pr.merged -eq $true -or $pr.merged_at) { 'merged' } else { ([string]$pr.state).ToLowerInvariant() }
        $mergeState = ([string]$pr.mergeable_state).ToLowerInvariant()
        if (-not $mergeState) { $mergeState = 'unknown' }
        return [pscustomobject]@{
            Number = [int]$pr.number; Title = (ConvertTo-GangplankReviewText $pr.title 300)
            State = $state; Author = (ConvertTo-GangplankReviewText $pr.user.login 100)
            Source = [string]$pr.head.ref; Target = [string]$pr.base.ref; Url = [string]$pr.html_url
            Draft = ($pr.draft -eq $true); HeadSha = [string]$pr.head.sha
            MergeState = $mergeState; Description = (ConvertTo-GangplankReviewText $pr.body $script:GangplankReviewDescriptionMax)
            Raw = $pr
        }
    }
    $project = $provider.EncodePath([string]$Session.ProjectPath)
    $mr = $provider.InvokeApi('GET',"projects/$project/merge_requests/$Number")
    if (-not $mr -or -not $mr.iid) { throw 'NOT_FOUND|That review request was not found.' }
    $glState = switch (([string]$mr.state).ToLowerInvariant()) { 'opened' { 'open' } default { ([string]$mr.state).ToLowerInvariant() } }
    $glMerge = ([string]$mr.detailed_merge_status).ToLowerInvariant()
    if (-not $glMerge) { $glMerge = ([string]$mr.merge_status).ToLowerInvariant() }
    if (-not $glMerge) { $glMerge = 'unknown' }
    return [pscustomobject]@{
        Number = [int]$mr.iid; Title = (ConvertTo-GangplankReviewText $mr.title 300)
        State = $glState; Author = (ConvertTo-GangplankReviewText $mr.author.username 100)
        Source = [string]$mr.source_branch; Target = [string]$mr.target_branch; Url = [string]$mr.web_url
        Draft = ($mr.draft -eq $true -or $mr.work_in_progress -eq $true); HeadSha = [string]$mr.sha
        MergeState = $glMerge; Description = (ConvertTo-GangplankReviewText $mr.description $script:GangplankReviewDescriptionMax)
        Raw = $mr
    }
}

function ConvertTo-GangplankCheckState {
    # Provider run/status word -> passing | failing | pending.
    param([string]$Provider,[string]$Status,[string]$Conclusion)
    $s = $Status.ToLowerInvariant(); $c = $Conclusion.ToLowerInvariant()
    if ($Provider -eq 'GitHub' -and $s -and $s -ne 'completed') { return 'pending' }
    $word = if ($Provider -eq 'GitHub' -and $c) { $c } else { $s }
    switch ($word) {
        { $_ -in @('success','neutral','skipped','passed') } { return 'passing' }
        { $_ -in @('failure','error','timed_out','cancelled','canceled','canceling','action_required','startup_failure','stale','failed') } { return 'failing' }
        default { return 'pending' }
    }
}

function New-GangplankChecksSummary {
    param([object[]]$Items,[string[]]$Notes = @())
    $items = @($Items | Where-Object { $_ })
    $failing = @($items | Where-Object { $_.State -eq 'failing' }).Count
    $pending = @($items | Where-Object { $_.State -eq 'pending' }).Count
    $passing = @($items | Where-Object { $_.State -eq 'passing' }).Count
    $status = if ($items.Count -eq 0) { 'none' } elseif ($failing -gt 0) { 'failing' } elseif ($pending -gt 0) { 'pending' } else { 'passing' }
    $text = switch ($status) {
        'none' { 'No checks have reported on the latest version.' }
        default { '{0} passing, {1} failing, {2} still running or waiting.' -f $passing,$failing,$pending }
    }
    return [pscustomobject]@{ Status = $status; Summary = $text; Passing = $passing; Failing = $failing; Pending = $pending; Items = @($items | Select-Object -First 30) }
}

function Get-GangplankReviewChecks {
    # GitHub: check runs plus commit statuses for the head sha. GitLab: the head pipeline.
    # A provider that will not show checks (permissions) gives status 'unknown', not an error.
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Core)
    $provider = $Session.ProviderObj
    $items = New-Object System.Collections.Generic.List[object]
    try {
        if ($Session.Provider -eq 'GitHub') {
            if (-not $Core.HeadSha) { return (New-GangplankChecksSummary -Items @()) }
            $sha = [uri]::EscapeDataString($Core.HeadSha)
            $runs = $provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/commits/$sha/check-runs?per_page=100")
            foreach ($r in @($runs.check_runs)) {
                if (-not $r) { continue }
                [void]$items.Add([pscustomobject]@{
                    Name = (ConvertTo-GangplankReviewText $r.name 120)
                    State = (ConvertTo-GangplankCheckState -Provider 'GitHub' -Status ([string]$r.status) -Conclusion ([string]$r.conclusion))
                    Detail = (ConvertTo-GangplankReviewText $(if ($r.conclusion) { $r.conclusion } else { $r.status }) 40)
                })
            }
            $combined = $provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/commits/$sha/status")
            foreach ($s in @($combined.statuses)) {
                if (-not $s) { continue }
                [void]$items.Add([pscustomobject]@{
                    Name = (ConvertTo-GangplankReviewText $s.context 120)
                    State = (ConvertTo-GangplankCheckState -Provider 'GitHub' -Status 'completed' -Conclusion ([string]$s.state))
                    Detail = (ConvertTo-GangplankReviewText $s.state 40)
                })
            }
        } else {
            $pipeline = $Core.Raw.head_pipeline
            if ($pipeline -and $pipeline.status) {
                [void]$items.Add([pscustomobject]@{
                    Name = 'Pipeline'
                    State = (ConvertTo-GangplankCheckState -Provider 'GitLab' -Status ([string]$pipeline.status) -Conclusion '')
                    Detail = (ConvertTo-GangplankReviewText $pipeline.status 40)
                })
            }
        }
    } catch {
        Write-GangplankLog -Level WARN -Message ("Review checks unavailable: {0}" -f (Get-GangplankSafeErrorMessage -Message $_.Exception.Message))
        return [pscustomobject]@{ Status = 'unknown'; Summary = 'The checks could not be read. Open the review request on the provider to see them.'; Passing = 0; Failing = 0; Pending = 0; Items = @() }
    }
    return (New-GangplankChecksSummary -Items $items.ToArray())
}

function Get-GangplankReviewComments {
    # Conversation, oldest first: GitHub issue comments, GitLab notes (system notes left out).
    # Reads up to 3 pages of 100 and keeps the latest 100.
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][int]$Number)
    $provider = $Session.ProviderObj
    $all = New-Object System.Collections.Generic.List[object]
    $moreMayExist = $false
    for ($page = 1; $page -le 3; $page++) {
        if ($Session.Provider -eq 'GitHub') {
            $batch = @($provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/issues/$Number/comments?per_page=100&page=$page"))
        } else {
            $project = $provider.EncodePath([string]$Session.ProjectPath)
            $batch = @($provider.InvokeApi('GET',"projects/$project/merge_requests/$Number/notes?sort=asc&order_by=created_at&per_page=100&page=$page"))
        }
        $batch = @($batch | Where-Object { $_ })
        foreach ($c in $batch) {
            if ($Session.Provider -eq 'GitLab' -and $c.system -eq $true) { continue }
            $author = if ($Session.Provider -eq 'GitHub') { $c.user.login } else { $c.author.username }
            [void]$all.Add([pscustomobject]@{
                Id = [string]$c.id; Author = (ConvertTo-GangplankReviewText $author 100)
                Created = [string]$c.created_at; Body = (ConvertTo-GangplankReviewText $c.body $script:GangplankReviewTextMax)
            })
        }
        if ($batch.Count -lt 100) { $moreMayExist = $false; break }
        $moreMayExist = ($page -eq 3)
    }
    $kept = @($all.ToArray() | Select-Object -Last 100)
    return [pscustomobject]@{ Items = $kept; Truncated = ($moreMayExist -or $all.Count -gt 100) }
}

function Get-GangplankReviewFiles {
    # Changed files, metadata only (never file contents).
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][int]$Number)
    $provider = $Session.ProviderObj
    if ($Session.Provider -eq 'GitHub') {
        $raw = @($provider.InvokeApi('GET',"repos/$($Session.ProjectPath)/pulls/$Number/files?per_page=100") | Where-Object { $_ })
        $files = @($raw | Select-Object -First 100 | ForEach-Object {
            [pscustomobject]@{ Path = (ConvertTo-GangplankReviewText $_.filename 400); Status = [string]$_.status; Additions = [int]$_.additions; Deletions = [int]$_.deletions }
        })
    } else {
        $project = $provider.EncodePath([string]$Session.ProjectPath)
        $raw = @($provider.InvokeApi('GET',"projects/$project/merge_requests/$Number/diffs?per_page=100") | Where-Object { $_ })
        $files = @($raw | Select-Object -First 100 | ForEach-Object {
            $kind = if ($_.new_file) { 'added' } elseif ($_.deleted_file) { 'removed' } elseif ($_.renamed_file) { 'renamed' } else { 'modified' }
            [pscustomobject]@{ Path = (ConvertTo-GangplankReviewText $_.new_path 400); Status = $kind; Additions = $null; Deletions = $null }
        })
    }
    return [pscustomobject]@{ Items = $files; Truncated = ($raw.Count -ge 100) }
}

function Get-GangplankReviewMergeVerdict {
    # Can this review be merged now? Reads the provider's own opinion (mergeable state,
    # draft flag); never decides on its own that something is safe. Reasons are plain language.
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)]$Core,$Checks)
    $warnings = New-Object System.Collections.Generic.List[string]
    $refuse = { param($text) return [pscustomobject]@{ CanMerge = $false; Reason = $text; Warnings = @() } }
    if ($Core.State -ne 'open') { return (& $refuse 'This review request is already closed or merged.') }
    if ($Core.Draft) { return (& $refuse 'This is a draft. The author needs to mark it ready for review before it can be merged.') }
    if (-not $Core.HeadSha) { return (& $refuse 'The latest version of the branch could not be read, so it cannot be merged from here.') }
    $conflict = 'The two branches have conflicting changes. Fix them on the provider site or update the branch, then check again.'
    if ($Provider -eq 'GitHub') {
        switch ($Core.MergeState) {
            'dirty' { return (& $refuse $conflict) }
            'blocked' { return (& $refuse 'GitHub says this is blocked: required checks or approvals are not finished yet.') }
            'behind' { return (& $refuse 'The branch is behind the main project and must be updated first.') }
            'draft' { return (& $refuse 'This is a draft. The author needs to mark it ready for review before it can be merged.') }
            { $_ -in @('unknown','') } { return (& $refuse 'GitHub is still working out whether this can be merged. Wait a moment, then refresh.') }
        }
    } else {
        switch ($Core.MergeState) {
            'mergeable' { }
            'can_be_merged' { }
            { $_ -in @('checking','unchecked','preparing','unknown') } { return (& $refuse 'GitLab is still working out whether this can be merged. Wait a moment, then refresh.') }
            { $_ -in @('conflict','cannot_be_merged') } { return (& $refuse $conflict) }
            'ci_must_pass' { return (& $refuse 'The project requires the checks to pass before merging, and they have not passed yet.') }
            'ci_still_running' { return (& $refuse 'The checks are still running. Wait for them to finish.') }
            'draft_status' { return (& $refuse 'This is a draft. The author needs to mark it ready for review before it can be merged.') }
            'not_approved' { return (& $refuse 'This needs approval from a teammate before it can be merged.') }
            'requested_changes' { return (& $refuse 'A reviewer asked for changes. They need to be dealt with first.') }
            'discussions_not_resolved' { return (& $refuse 'Some conversations are not resolved yet.') }
            'need_rebase' { return (& $refuse 'The branch must be updated first. Update it on GitLab, then check again.') }
            'not_open' { return (& $refuse 'This review request is already closed or merged.') }
            'blocked_status' { return (& $refuse 'This is blocked by another review request that must be merged first.') }
            default {
                $word = if ($Core.MergeState -match '^[a-z_]{1,40}$') { $Core.MergeState } else { 'unknown' }
                return (& $refuse ("GitLab says this cannot be merged yet ({0}). Open it on GitLab to see why." -f $word))
            }
        }
    }
    if ($Checks -and $Checks.Status -eq 'failing') { [void]$warnings.Add('Some checks are failing. Make sure that is expected before you merge.') }
    elseif ($Checks -and $Checks.Status -eq 'pending') { [void]$warnings.Add('Some checks are still running.') }
    return [pscustomobject]@{ CanMerge = $true; Reason = ''; Warnings = @($warnings.ToArray()) }
}

function Get-GangplankReviewDetail {
    # Everything the Reviews tab shows for one open review request. Read-only.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Number)
    Assert-GangplankReviewProvider -Session $Session
    $n = ConvertTo-GangplankReviewNumber $Number
    [void](Assert-GangplankOpenReview -Session $Session -Number $n)
    $core = Get-GangplankReviewCore -Session $Session -Number $n
    $notes = New-Object System.Collections.Generic.List[string]
    $checks = Get-GangplankReviewChecks -Session $Session -Core $core
    $comments = [pscustomobject]@{ Items = @(); Truncated = $false }
    try { $comments = Get-GangplankReviewComments -Session $Session -Number $n }
    catch { [void]$notes.Add('The conversation could not be read.'); Write-GangplankLog -Level WARN -Message ("Review comments unavailable: {0}" -f (Get-GangplankSafeErrorMessage -Message $_.Exception.Message)) }
    $files = [pscustomobject]@{ Items = @(); Truncated = $false }
    try { $files = Get-GangplankReviewFiles -Session $Session -Number $n }
    catch { [void]$notes.Add('The changed file list could not be read.'); Write-GangplankLog -Level WARN -Message ("Review files unavailable: {0}" -f (Get-GangplankSafeErrorMessage -Message $_.Exception.Message)) }
    $verdict = Get-GangplankReviewMergeVerdict -Provider $Session.Provider -Core $core -Checks $checks
    return [pscustomobject]@{
        Number = $core.Number; Title = $core.Title; State = $core.State; Author = $core.Author
        Source = $core.Source; Target = $core.Target; Url = $core.Url; Draft = $core.Draft
        HeadSha = $core.HeadSha; MergeState = $core.MergeState; Description = $core.Description
        Checks = $checks
        Comments = @($comments.Items); CommentsTruncated = [bool]$comments.Truncated
        Files = @($files.Items); FilesTruncated = [bool]$files.Truncated
        CanMerge = [bool]$verdict.CanMerge; CanMergeReason = [string]$verdict.Reason
        Warnings = @($verdict.Warnings); Notes = @($notes.ToArray())
        CommentLimit = $script:GangplankReviewCommentMax
        Explanation = 'Merging combines this work into the target branch. Gangplank never forces a merge and never deletes the work branch.'
    }
}

function Add-GangplankReviewComment {
    # Reply to a review request. Plain text, 1..4000 characters.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Number,[Parameter(Mandatory)][string]$Text)
    $body = ConvertTo-GangplankReviewCommentText -Text $Text
    $n = ConvertTo-GangplankReviewNumber $Number
    [void](Assert-GangplankOpenReview -Session $Session -Number $n)
    $provider = $Session.ProviderObj
    if ($Session.Provider -eq 'GitHub') {
        $made = $provider.InvokeApi('POST',"repos/$($Session.ProjectPath)/issues/$n/comments",@{ body = $body })
        $author = $made.user.login
    } else {
        $project = $provider.EncodePath([string]$Session.ProjectPath)
        $made = $provider.InvokeApi('POST',"projects/$project/merge_requests/$n/notes",@{ body = $body })
        $author = $made.author.username
    }
    Write-GangplankLog -Level INFO -Message "Comment added to review #$n"
    Write-GangplankAudit -Action 'review.commented' -Data @{ provider = [string]$Session.Provider; project = [string]$Session.ProjectPath; number = $n; length = $body.Length }
    return [pscustomobject]@{
        Id = [string]$made.id; Author = (ConvertTo-GangplankReviewText $author 100)
        Created = [string]$made.created_at; Body = (ConvertTo-GangplankReviewText $made.body $script:GangplankReviewTextMax)
    }
}

function ConvertTo-GangplankMergeRefusal {
    # A provider refusal (405/406/409/422) as a clear coded message; $null for anything else.
    param([string]$Provider,[string]$Message)
    $http = 0
    if ($Message -match '\(HTTP ([0-9]{3})\)') { $http = [int]$Matches[1] }
    if ($http -eq 409) { return 'CONFLICT|The branch changed while you were merging. Refresh the review request, check the new changes, then try again.' }
    if ($http -in @(405,406,422)) {
        return ("BAD_STATE|{0} refused the merge. A required check, an approval, a conflict or a project rule is probably blocking it. Open the review request on {0} to see why." -f $Provider)
    }
    return $null
}

function Merge-GangplankReview {
    # Merge one open review request. Never forced. Needs -Confirmed:$true and the head sha the user saw.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Number,[Parameter(Mandatory)][string]$Sha,[bool]$Confirmed = $false)
    if ($Confirmed -ne $true) { throw 'BAD_REQUEST|Confirm the merge first. Nothing was merged.' }
    if ($Sha -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'BAD_REQUEST|The version to merge is missing. Reload the review request and try again.' }
    $n = ConvertTo-GangplankReviewNumber $Number
    Assert-GangplankReviewProvider -Session $Session
    $core = $null
    try {
        [void](Assert-GangplankOpenReview -Session $Session -Number $n)
        $core = Get-GangplankReviewCore -Session $Session -Number $n
        # Stale guard: merge exactly the version the user looked at.
        if ([string]$core.HeadSha -ine $Sha) {
            throw 'CONFLICT|The review request changed since you opened it. Reload it, look at the new changes, then merge.'
        }
        $verdict = Get-GangplankReviewMergeVerdict -Provider $Session.Provider -Core $core
        if (-not $verdict.CanMerge) { throw ('BAD_STATE|' + $verdict.Reason) }
        $provider = $Session.ProviderObj
        $mergeCommit = ''
        try {
            if ($Session.Provider -eq 'GitHub') {
                $done = $provider.InvokeApi('PUT',"repos/$($Session.ProjectPath)/pulls/$n/merge",@{ merge_method = 'merge'; sha = $core.HeadSha })
                if (-not $done -or $done.merged -ne $true) { throw 'BAD_STATE|GitHub did not complete the merge. Open the review request on GitHub to see why.' }
                $mergeCommit = [string]$done.sha
            } else {
                $project = $provider.EncodePath([string]$Session.ProjectPath)
                $done = $provider.InvokeApi('PUT',"projects/$project/merge_requests/$n/merge",@{ sha = $core.HeadSha; should_remove_source_branch = $false; squash = $false })
                if (-not $done -or [string]$done.state -ne 'merged') { throw 'BAD_STATE|GitLab did not complete the merge. Open the review request on GitLab to see why.' }
                $mergeCommit = [string]$done.merge_commit_sha
            }
        } catch {
            $message = [string]$_.Exception.Message
            $refusal = ConvertTo-GangplankMergeRefusal -Provider ([string]$Session.Provider) -Message $message
            if ($refusal) { throw $refusal }
            throw
        }
    } catch {
        $message = [string]$_.Exception.Message
        $code = if ($message -match '^([A-Z][A-Z0-9_]{2,40})\|') { $Matches[1] } else { 'FAILED' }
        Write-GangplankAudit -Action 'review.merge.refused' -Data @{ provider = [string]$Session.Provider; project = [string]$Session.ProjectPath; number = $n; code = $code }
        throw
    }
    Write-GangplankLog -Level INFO -Message "Review #$n merged into $($core.Target)"
    Write-GangplankAudit -Action 'review.merged' -Data @{ provider = [string]$Session.Provider; project = [string]$Session.ProjectPath; number = $n; source = $core.Source; target = $core.Target; sha = $core.HeadSha; mergeCommit = $mergeCommit }
    return [pscustomobject]@{ Merged = $true; Number = $n; Source = $core.Source; Target = $core.Target; Sha = $core.HeadSha; MergeCommit = $mergeCommit; Url = $core.Url }
}
