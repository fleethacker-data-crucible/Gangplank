#Requires -Version 5.1
# =============================================================================
# Job functions. Each runs inside a job runspace (Server/Jobs.ps1) with
# -Shared (progress/chunks) and -Arguments (plain data, including the token the
# host resolved on its main thread). Each returns plain data; the host applies
# it to the live session on the main thread.
# =============================================================================

function Invoke-GangplankJobConnect {
    param($Shared,[hashtable]$Arguments)
    Set-GangplankJobProgress $Shared 'Checking repository access'
    $session = Open-GangplankRepository -Url $Arguments.Url -Token $Arguments.Token
    return @{ Session = (ConvertTo-GangplankSessionSnapshot $session) }
}

function Invoke-GangplankJobStart {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Creating your work branch'
    $branch = New-GangplankWorkBranch -Session $session -Name ([string]$Arguments.Name)
    Set-GangplankJobProgress $Shared 'Downloading a fresh copy'
    $folder = Get-GangplankSafeWorkspacePath -Base $Arguments.WorkRoot -Project $session.ProjectPath -Branch $branch
    [void](Invoke-GangplankPull -Session $session -Branch $branch -LocalPath $folder)
    return @{ Session = (ConvertTo-GangplankSessionSnapshot $session); Folder = $session.LocalPath; Branch = $branch; Sha = $session.BaselineSha }
}

function Invoke-GangplankJobDownload {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    $branch = if ($Arguments.Branch) { [string]$Arguments.Branch } else { [string]$session.DefaultBranch }
    Set-GangplankJobProgress $Shared "Downloading $branch"
    $folder = Get-GangplankSafeWorkspacePath -Base $Arguments.WorkRoot -Project $session.ProjectPath -Branch $branch
    [void](Invoke-GangplankPull -Session $session -Branch $branch -LocalPath $folder)
    return @{ Session = (ConvertTo-GangplankSessionSnapshot $session); Folder = $session.LocalPath; Branch = $branch; Sha = $session.BaselineSha }
}

function Invoke-GangplankJobAdopt {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Comparing the folder with the project'
    $r = Add-GangplankExistingFolder -Session $session -Folder ([string]$Arguments.Folder) -Branch ([string]$Arguments.Branch)
    return @{
        Session = (ConvertTo-GangplankSessionSnapshot $session)
        Adopted = [ordered]@{
            folder = $r.Folder; branch = $r.Branch; sha = $r.Sha; source = $r.Source
            same = $r.Same; modified = $r.Modified; new = $r.New; missing = $r.Missing
            behind = $r.Behind; onDefaultBranch = $r.OnDefaultBranch
        }
    }
}

function Invoke-GangplankJobPublishFolder {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    # Check the folder before creating anything online.
    if (-not (Test-Path -LiteralPath ([string]$Arguments.Folder) -PathType Container)) { throw 'NOT_FOUND|That folder was not found.' }
    Set-GangplankJobProgress $Shared 'Creating your work branch'
    $branch = New-GangplankWorkBranch -Session $session -Name ([string]$Arguments.Name)
    Set-GangplankJobProgress $Shared 'Comparing the folder with the project'
    $r = Add-GangplankExistingFolder -Session $session -Folder ([string]$Arguments.Folder) -Branch $branch -Unrelated
    return @{
        Session = (ConvertTo-GangplankSessionSnapshot $session)
        Adopted = [ordered]@{
            folder = $r.Folder; branch = $r.Branch; sha = $r.Sha; source = 'published folder'
            same = $r.Same; modified = $r.Modified; new = $r.New; missing = $r.Missing
            behind = $r.Behind; onDefaultBranch = $r.OnDefaultBranch
        }
    }
}

function Invoke-GangplankJobSave {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Checking and publishing selected files'
    $saved = Invoke-GangplankWorkspaceSave -Session $session -SelectedPaths ([string[]]@($Arguments.Paths)) -Message ([string]$Arguments.Message) -PublicConfirmed:([bool]$Arguments.PublicConfirmed) -Acknowledgements $(if ($Arguments.Acknowledgements) { $Arguments.Acknowledgements } else { @{} })
    $session | Add-Member -MemberType NoteProperty -Name LastSaveMessage -Value $saved.Message -Force
    $session | Add-Member -MemberType NoteProperty -Name LastSavedFiles -Value @($Arguments.Paths) -Force
    $session | Add-Member -MemberType NoteProperty -Name LastReviewUrl -Value $null -Force
    return @{ Session = (ConvertTo-GangplankSessionSnapshot $session); Saved = $saved }
}

function Invoke-GangplankJobLatest {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Checking what changed online'
    $choices = @{}
    if ($Arguments.Choices) { foreach ($k in @($Arguments.Choices.Keys)) { $choices[[string]$k] = [string]$Arguments.Choices[$k] } }
    $r = Update-GangplankWorkspaceFromRemote -Session $session -Choices $choices
    return @{
        Session = (ConvertTo-GangplankSessionSnapshot $session)
        Latest = [ordered]@{ upToDate = $r.UpToDate; needsChoice = $r.NeedsChoice; applied = @($r.Applied); overlaps = @($r.Overlaps); head = $r.Head }
    }
}

function Invoke-GangplankJobRevert {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Getting the earlier version of the file'
    $r = Restore-GangplankWorkspaceFile -Session $session -Path ([string]$Arguments.Path)
    return @{ Path = $r.Path; Kind = $r.Kind; BackupPath = $r.BackupPath }
}

function Invoke-GangplankJobReview {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Creating the review request'
    $title = 'Review: ' + [string]$session.LastSaveMessage
    $desc = 'Created with Gangplank Smart Save.' + [char]10 + [char]10 + 'Files in most recent save:' + [char]10
    foreach ($p in @($session.LastSavedFiles)) { $desc += '- ' + $p + [char]10 }
    $review = New-GangplankMergeRequest -Session $session -SourceBranch $session.LastBranch -TargetBranch $session.DefaultBranch -Title $title -Description $desc
    $url = if ($review.html_url) { [string]$review.html_url } else { [string]$review.web_url }
    return @{ Url = $url; Title = $title }
}

function Invoke-GangplankJobAiExplain {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Asking the assistant'
    $answer = Invoke-GangplankAiExplain -Session $session -Path ([string]$Arguments.Path) -Consent ([string]$Arguments.Consent) -Token $Arguments.AiToken
    return [ordered]@{ answer = $answer }
}

function Invoke-GangplankJobReviewComment {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Posting your reply'
    $c = Add-GangplankReviewComment -Session $session -Number $Arguments.Number -Text ([string]$Arguments.Text)
    return [ordered]@{ number = [int]$Arguments.Number; id = $c.Id; author = $c.Author; created = $c.Created }
}

function Invoke-GangplankJobReviewMerge {
    param($Shared,[hashtable]$Arguments)
    $session = New-GangplankSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-GangplankJobProgress $Shared 'Merging the review request'
    $done = Merge-GangplankReview -Session $session -Number $Arguments.Number -Sha ([string]$Arguments.Sha) -Confirmed ($Arguments.Confirmed -eq $true)
    return [ordered]@{ merged = $true; number = $done.Number; source = $done.Source; target = $done.Target; sha = $done.Sha; mergeCommit = $done.MergeCommit; url = $done.Url }
}

function Invoke-GangplankJobCommitTitle {
    param($Shared,[hashtable]$Arguments)
    Set-GangplankJobProgress $Shared 'Asking Fairlead for a title'
    $diff = [pscustomobject]@{ New = @($Arguments.New); Modified = @($Arguments.Modified); Deleted = @($Arguments.Deleted) }
    $prompt = Get-GangplankSmartSavePrompt -Diff $diff
    $answer = Invoke-GangplankAI -Question $prompt -CommitTitle -Token $Arguments.AiToken
    $draft = New-GangplankSmartMessage -Added $diff.New -Modified $diff.Modified -Deleted $diff.Deleted -AiSuggestion $answer
    return [ordered]@{ title = $draft.Title; source = $draft.Source }
}

function Invoke-GangplankJobChat {
    param($Shared,[hashtable]$Arguments)
    Set-GangplankJobProgress $Shared 'Thinking'
    $context = $null
    if ($Arguments.Project) { $context = [pscustomobject]@{ ProjectPath = $Arguments.Project; LastBranch = $Arguments.Branch; DefaultBranch = $Arguments.Branch } }
    $chunks = $Shared.Chunks
    Invoke-GangplankAIStream -Question ([string]$Arguments.Question) -Session $context -Token $Arguments.AiToken -OnChunk { param($t) [void]$chunks.Add($t) }.GetNewClosure()
    Set-GangplankJobProgress $Shared 'Done'
    return [ordered]@{ characters = [int](($chunks | ForEach-Object { $_.Length }) | Measure-Object -Sum).Sum }
}

function Invoke-GangplankJobAiTest {
    param($Shared,[hashtable]$Arguments)
    Set-GangplankJobProgress $Shared 'Sending a short test message'
    return (Test-GangplankAiConnection -Token ([string]$Arguments.AiToken))
}

function Invoke-GangplankJobPullMany {
    param($Shared,[hashtable]$Arguments)
    $workRoot = [string]$Arguments.WorkRoot
    if ([string]::IsNullOrWhiteSpace($workRoot)) { throw 'BAD_STATE|Workspace root is not set.' }
    $projects = @($Arguments.Projects)
    if ($projects.Count -lt 1) { throw 'BAD_REQUEST|Select at least one project to pull.' }
    if ($projects.Count -gt 50) { throw 'BAD_REQUEST|Pull at most 50 projects at a time.' }

    $results = New-Object System.Collections.Generic.List[object]
    $lastSession = $null
    $i = 0
    foreach ($item in $projects) {
        $i++
        $url = [string]$item.Url
        $branch = [string]$item.Branch
        $pathHint = [string]$item.Path
        if ([string]::IsNullOrWhiteSpace($url)) {
            $results.Add([ordered]@{ ok = $false; path = $pathHint; url = $url; error = 'Missing URL' })
            continue
        }
        Set-GangplankJobProgress $Shared ("Pulling $i of $($projects.Count): " + $(if ($pathHint) { $pathHint } else { $url }))
        try {
            Assert-GangplankTrustedRepositoryUrl -Url $url
            $parsed = Parse-GangplankRepoUrl -Url $url
            $hostName = ''
            try { $hostName = ([uri]$parsed.BaseUrl).Host } catch { }
            $siteKey = if ($parsed.Provider -eq 'GitHub') { 'GitHub' } elseif ($hostName) { $hostName } else { 'GitLab' }
            $tokens = @(Get-GangplankCredentialsForSite -SiteKey $siteKey -TargetHost $hostName)
            if ($tokens.Count -eq 0) {
                $tokens = @((Resolve-GangplankCredential -Provider $siteKey -TargetHost $hostName).Value)
            }
            $session = $null
            $lastErr = $null
            foreach ($tok in $tokens) {
                try {
                    $session = Open-GangplankRepository -Url $url -Token $tok
                    break
                } catch {
                    $lastErr = $_
                }
            }
            if (-not $session) {
                if ($lastErr) { throw $lastErr }
                throw 'CREDENTIAL_MISSING|No usable token for this repository.'
            }
            if ([string]::IsNullOrWhiteSpace($branch)) { $branch = [string]$session.DefaultBranch }
            if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }
            $siteLabel = if ($session.Provider -eq 'GitHub') { 'github.com' } elseif ($hostName) { $hostName } else { 'gitlab' }
            $folder = Get-GangplankSafeWorkspacePath -Base $workRoot -Project $session.ProjectPath -Branch $branch -Site $siteLabel
            $already = $false
            if (Test-Path -LiteralPath $folder -PathType Container) {
                if (@(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                    $already = $true
                }
            }
            if ($already) {
                $session.LocalPath = [IO.Path]::GetFullPath($folder)
                $session.LastBranch = $branch
                $lastSession = $session
                $results.Add([ordered]@{
                    ok           = $true
                    alreadyLocal = $true
                    path         = $session.ProjectPath
                    branch       = $branch
                    folder       = $session.LocalPath
                    sha          = $session.BaselineSha
                    provider     = $session.Provider
                    url          = $url
                    note         = 'Already present under the workspace root (not re-downloaded).'
                })
            } else {
                [void](Invoke-GangplankPull -Session $session -Branch $branch -LocalPath $folder)
                $lastSession = $session
                $results.Add([ordered]@{
                    ok           = $true
                    alreadyLocal = $false
                    path         = $session.ProjectPath
                    branch       = $branch
                    folder       = $session.LocalPath
                    sha          = $session.BaselineSha
                    provider     = $session.Provider
                    url          = $url
                })
            }
        } catch {
            $msg = Get-GangplankSafeErrorMessage ([string]$_.Exception.Message)
            $results.Add([ordered]@{ ok = $false; path = $pathHint; url = $url; branch = $branch; error = $msg })
        }
    }
    $ok = @($results | Where-Object { $_.ok })
    $fail = @($results | Where-Object { -not $_.ok })
    Set-GangplankJobProgress $Shared ("Pulled $($ok.Count) of $($projects.Count) project(s)")
    $payload = [ordered]@{
        results = @($results)
        pulled  = $ok.Count
        failed  = $fail.Count
        folders = @($ok | ForEach-Object { $_.folder })
    }
    if ($lastSession) {
        $payload.Session = (ConvertTo-GangplankSessionSnapshot $lastSession)
        $payload.Folder  = $lastSession.LocalPath
        $payload.Branch  = $lastSession.LastBranch
        $payload.Sha     = $lastSession.BaselineSha
    }
    return $payload
}

function Invoke-GangplankJobListBranchesMany {
    param($Shared,[hashtable]$Arguments)
    $kind = [string]$Arguments.Provider
    if ($kind -ne 'GitHub') { $kind = 'GitLab' }
    $hostName = [string]$Arguments.HostName
    $base = [string]$Arguments.BaseUrl
    if (-not $base) {
        if ($kind -eq 'GitHub') { $base = 'https://github.com' }
        else {
            $h = if ($hostName) { $hostName } else { Get-GangplankGitLabHost }
            if (-not $h) { throw 'BAD_REQUEST|GitLab host is required.' }
            $base = "https://$h"
        }
    }
    $tokenList = New-Object System.Collections.Generic.List[string]
    if ($Arguments.ContainsKey('Tokens') -and $null -ne $Arguments.Tokens) {
        foreach ($t in @($Arguments.Tokens)) {
            $s = [string]$t
            if (-not [string]::IsNullOrWhiteSpace($s) -and $s.Length -ge 8) { [void]$tokenList.Add($s) }
        }
    }
    if ($tokenList.Count -eq 0 -and $Arguments.ContainsKey('Token')) {
        $s = [string]$Arguments.Token
        if ($s) { [void]$tokenList.Add($s) }
    }
    if ($tokenList.Count -eq 0) { throw 'CREDENTIAL_MISSING|No token available to list branches.' }

    $projects = @($Arguments.Projects)
    if ($projects.Count -lt 1) { throw 'BAD_REQUEST|No projects provided.' }
    if ($projects.Count -gt 100) { $projects = $projects[0..99] }

    $map = [ordered]@{}
    $ok = 0
    $fail = 0
    $i = 0
    foreach ($item in $projects) {
        $i++
        $path = ''
        if ($item -is [string]) { $path = [string]$item }
        elseif ($item.path) { $path = [string]$item.path }
        elseif ($item.Path) { $path = [string]$item.Path }
        if (-not $path) { continue }
        Set-GangplankJobProgress $Shared ("Branches $i of $($projects.Count): $path")
        $got = $null
        $lastErr = $null
        foreach ($tok in $tokenList) {
            try {
                $got = Get-GangplankProjectBranchList -Provider $kind -ProjectPath $path -Token $tok -BaseUrl $base
                if (@($got.branches).Count -gt 0) { break }
            } catch {
                $lastErr = $_
                $got = $null
            }
        }
        if ($got) {
            $ok++
            $map[$path] = [ordered]@{
                path          = $path
                branches      = @($got.branches)
                defaultBranch = [string]$got.defaultBranch
                ok            = $true
            }
        } else {
            $fail++
            $msg = if ($lastErr) { Get-GangplankSafeErrorMessage ([string]$lastErr.Exception.Message) } else { 'No branches returned' }
            $map[$path] = [ordered]@{
                path          = $path
                branches      = @()
                defaultBranch = ''
                ok            = $false
                error         = $msg
            }
        }
    }
    Set-GangplankJobProgress $Shared ("Branches loaded for $ok of $($projects.Count)")
    return [ordered]@{
        provider = $kind
        host     = $hostName
        count    = $projects.Count
        ok       = $ok
        failed   = $fail
        results  = @($map.Values)
        byPath   = $map
    }
}

function Invoke-GangplankJobListProjects {
    param($Shared,[hashtable]$Arguments)
    $site = [string]$Arguments.Provider
    $hostName = [string]$Arguments.HostName
    if (-not $hostName -and $site -ne 'GitHub' -and $site -ne 'GitLab') { $hostName = $site }
    $label = if ($hostName) { $hostName } else { $site }
    Set-GangplankJobProgress $Shared "Listing writable $label projects"
    $kind = if ($site -eq 'GitHub') { 'GitHub' } else { 'GitLab' }
    # Flatten Tokens to a real string[] (never enumerate a single string as chars).
    $tokenList = New-Object System.Collections.Generic.List[string]
    if ($Arguments.ContainsKey('Tokens') -and $null -ne $Arguments.Tokens) {
        foreach ($t in @($Arguments.Tokens)) {
            $s = [string]$t
            if (-not [string]::IsNullOrWhiteSpace($s) -and $s.Length -ge 8) { [void]$tokenList.Add($s) }
        }
    }
    if ($tokenList.Count -eq 0 -and $Arguments.ContainsKey('Token') -and $Arguments.Token) {
        $s = [string]$Arguments.Token
        if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$tokenList.Add($s) }
    }
    if ($tokenList.Count -eq 0) { throw 'CREDENTIAL_MISSING|No token available to list projects.' }
    $merged = @{}
    for ($tokenIndex = 0; $tokenIndex -lt $tokenList.Count; $tokenIndex++) {
        $tok = $tokenList[$tokenIndex]
        Set-GangplankJobProgress $Shared ("Listing $label with token " + ($tokenIndex + 1) + " of " + $tokenList.Count)
        try {
            $batch = @(Get-GangplankWritableProjects -Provider $kind -Token $tok -HostName $hostName)
        } catch {
            Write-GangplankLog -Level WARN -Message "List projects with token $($tokenIndex + 1) failed: $($_.Exception.Message)"
            continue
        }
        foreach ($proj in @($batch)) {
            if ($null -eq $proj) { continue }
            $path = [string]$proj.path
            if (-not $path) { continue }
            if (-not $merged.ContainsKey($path)) {
                $merged[$path] = $proj
                continue
            }
            $cur = $merged[$path]
            $curDesc = if ($cur.description) { [string]$cur.description } else { '' }
            $newDesc = if ($proj.description) { [string]$proj.description } else { '' }
            if ($newDesc.Length -gt $curDesc.Length) { $cur.description = $proj.description }
            if ((-not $cur.defaultBranch) -and $proj.defaultBranch) { $cur.defaultBranch = $proj.defaultBranch }
            if ($proj.visibility -and ((-not $cur.visibility) -or $cur.visibility -eq 'public')) { $cur.visibility = $proj.visibility }
            $merged[$path] = $cur
        }
    }
    $items = @($merged.Values | Sort-Object { [string]$_.path })
    Set-GangplankJobProgress $Shared "Found $($items.Count) writable project(s) across $($tokenList.Count) token(s)"
    return [ordered]@{ provider = $kind; site = $(if ($hostName) { $hostName } else { $site }); projects = $items; count = $items.Count; tokensTried = $tokenList.Count }
}

function Invoke-GangplankJobSync {
    param($Shared,[hashtable]$Arguments)
    $progress = { param($m) Set-GangplankJobProgress $Shared $m }.GetNewClosure()
    return (Invoke-GangplankSyncTransfer `
        -SourceProvider ([string]$Arguments.SourceProvider) `
        -SourceProject ([string]$Arguments.SourceProject) `
        -SourceBranch ([string]$Arguments.SourceBranch) `
        -SourceToken ([string]$Arguments.SourceToken) `
        -SourceBaseUrl ([string]$Arguments.SourceBaseUrl) `
        -TargetProvider ([string]$Arguments.TargetProvider) `
        -TargetProject ([string]$Arguments.TargetProject) `
        -TargetBranch ([string]$Arguments.TargetBranch) `
        -TargetToken ([string]$Arguments.TargetToken) `
        -TargetBaseUrl ([string]$Arguments.TargetBaseUrl) `
        -Message ([string]$Arguments.Message) `
        -CreateTargetBranch:([bool]$Arguments.CreateTargetBranch) `
        -TargetBaseBranch ([string]$Arguments.TargetBaseBranch) `
        -Progress $progress)
}
