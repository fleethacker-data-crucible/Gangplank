#Requires -Version 5.1
# =============================================================================
# Job functions. Each runs inside a job runspace (Server/Jobs.ps1) with
# -Shared (progress/chunks) and -Arguments (plain data, including the token the
# host resolved on its main thread). Each returns plain data; the host applies
# it to the live session on the main thread.
# =============================================================================

function Invoke-KeystoneJobConnect {
    param($Shared,[hashtable]$Arguments)
    Set-KeystoneJobProgress $Shared 'Checking repository access'
    $session = Open-KeystoneRepository -Url $Arguments.Url -Token $Arguments.Token
    return @{ Session = (ConvertTo-KeystoneSessionSnapshot $session) }
}

function Invoke-KeystoneJobStart {
    param($Shared,[hashtable]$Arguments)
    $session = New-KeystoneSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-KeystoneJobProgress $Shared 'Creating your work branch'
    $branch = New-KeystoneWorkBranch -Session $session -Name ([string]$Arguments.Name)
    Set-KeystoneJobProgress $Shared 'Downloading a fresh copy'
    $folder = Get-KeystoneSafeWorkspacePath -Base $Arguments.WorkRoot -Project $session.ProjectPath -Branch $branch
    [void](Invoke-KeystonePull -Session $session -Branch $branch -LocalPath $folder)
    return @{ Session = (ConvertTo-KeystoneSessionSnapshot $session); Folder = $session.LocalPath; Branch = $branch; Sha = $session.BaselineSha }
}

function Invoke-KeystoneJobDownload {
    param($Shared,[hashtable]$Arguments)
    $session = New-KeystoneSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    $branch = if ($Arguments.Branch) { [string]$Arguments.Branch } else { [string]$session.DefaultBranch }
    Set-KeystoneJobProgress $Shared "Downloading $branch"
    $folder = Get-KeystoneSafeWorkspacePath -Base $Arguments.WorkRoot -Project $session.ProjectPath -Branch $branch
    [void](Invoke-KeystonePull -Session $session -Branch $branch -LocalPath $folder)
    return @{ Session = (ConvertTo-KeystoneSessionSnapshot $session); Folder = $session.LocalPath; Branch = $branch; Sha = $session.BaselineSha }
}

function Invoke-KeystoneJobSave {
    param($Shared,[hashtable]$Arguments)
    $session = New-KeystoneSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-KeystoneJobProgress $Shared 'Checking and publishing selected files'
    $saved = Invoke-KeystoneWorkspaceSave -Session $session -SelectedPaths ([string[]]@($Arguments.Paths)) -Message ([string]$Arguments.Message) -PublicConfirmed:([bool]$Arguments.PublicConfirmed)
    $session | Add-Member -MemberType NoteProperty -Name LastSaveMessage -Value $saved.Message -Force
    $session | Add-Member -MemberType NoteProperty -Name LastSavedFiles -Value @($Arguments.Paths) -Force
    $session | Add-Member -MemberType NoteProperty -Name LastReviewUrl -Value $null -Force
    return @{ Session = (ConvertTo-KeystoneSessionSnapshot $session); Saved = $saved }
}

function Invoke-KeystoneJobReview {
    param($Shared,[hashtable]$Arguments)
    $session = New-KeystoneSessionFromSnapshot -Snapshot $Arguments.Session -Token $Arguments.Token
    Set-KeystoneJobProgress $Shared 'Creating the review request'
    $title = 'Review: ' + [string]$session.LastSaveMessage
    $desc = 'Created with Keystone Smart Save.' + [char]10 + [char]10 + 'Files in most recent save:' + [char]10
    foreach ($p in @($session.LastSavedFiles)) { $desc += '- ' + $p + [char]10 }
    $review = New-KeystoneMergeRequest -Session $session -SourceBranch $session.LastBranch -TargetBranch $session.DefaultBranch -Title $title -Description $desc
    $url = if ($review.html_url) { [string]$review.html_url } else { [string]$review.web_url }
    return @{ Url = $url; Title = $title }
}

function Invoke-KeystoneJobCommitTitle {
    param($Shared,[hashtable]$Arguments)
    Set-KeystoneJobProgress $Shared 'Asking the AI gateway for a title'
    $diff = [pscustomobject]@{ New = @($Arguments.New); Modified = @($Arguments.Modified); Deleted = @($Arguments.Deleted) }
    $prompt = Get-KeystoneSmartSavePrompt -Diff $diff
    $answer = Invoke-KeystoneAI -Question $prompt -CommitTitle -Token $Arguments.AiToken
    $draft = New-KeystoneSmartMessage -Added $diff.New -Modified $diff.Modified -Deleted $diff.Deleted -AiSuggestion $answer
    return [ordered]@{ title = $draft.Title; source = $draft.Source }
}

function Invoke-KeystoneJobChat {
    param($Shared,[hashtable]$Arguments)
    Set-KeystoneJobProgress $Shared 'Thinking'
    $context = $null
    if ($Arguments.Project) { $context = [pscustomobject]@{ ProjectPath = $Arguments.Project; LastBranch = $Arguments.Branch; DefaultBranch = $Arguments.Branch } }
    $chunks = $Shared.Chunks
    Invoke-KeystoneAIStream -Question ([string]$Arguments.Question) -Session $context -Token $Arguments.AiToken -OnChunk { param($t) [void]$chunks.Add($t) }.GetNewClosure()
    Set-KeystoneJobProgress $Shared 'Done'
    return [ordered]@{ characters = [int](($chunks | ForEach-Object { $_.Length }) | Measure-Object -Sum).Sum }
}

function Invoke-KeystoneJobAiDetect {
    param($Shared,[hashtable]$Arguments)
    Set-KeystoneJobProgress $Shared 'Asking the endpoint which models it offers'
    return (Find-KeystoneAiModels -Endpoint ([string]$Arguments.Endpoint) -Token ([string]$Arguments.AiToken) -Current ([string]$Arguments.Current))
}

function Invoke-KeystoneJobAiTest {
    param($Shared,[hashtable]$Arguments)
    Set-KeystoneJobProgress $Shared 'Sending a short test message'
    return (Test-KeystoneAiConnection -Token ([string]$Arguments.AiToken))
}
