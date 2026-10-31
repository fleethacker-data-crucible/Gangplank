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
    Set-GangplankJobProgress $Shared 'Asking the AI gateway for a title'
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

function Invoke-GangplankJobAiDetect {
    param($Shared,[hashtable]$Arguments)
    Set-GangplankJobProgress $Shared 'Asking the endpoint which models it offers'
    return (Find-GangplankAiModels -Endpoint ([string]$Arguments.Endpoint) -Token ([string]$Arguments.AiToken) -Current ([string]$Arguments.Current))
}

function Invoke-GangplankJobAiTest {
    param($Shared,[hashtable]$Arguments)
    Set-GangplankJobProgress $Shared 'Sending a short test message'
    return (Test-GangplankAiConnection -Token ([string]$Arguments.AiToken))
}
