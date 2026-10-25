#Requires -Version 5.1
# Deterministic, offline-first change summaries. No file contents leave the workstation.
function New-GangplankSmartMessage {
    [CmdletBinding()]
    param(
        [string[]]$Added = @(),
        [string[]]$Modified = @(),
        [string[]]$Deleted = @(),
        [string]$AiSuggestion
    )
    $all = @($Added) + @($Modified) + @($Deleted)
    $all = @($all | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($all.Count -eq 0) { return [pscustomobject]@{ Title = 'No changes'; Summary = 'Nothing to save.'; HasChanges = $false; Source = 'local' } }
    $areas = @($all | ForEach-Object { ($_.Replace('\\','/') -split '/')[0] } | Sort-Object -Unique)
    $scope = if ($areas.Count -eq 1 -and $areas[0] -notmatch '\.') { $areas[0].ToLowerInvariant() } else { 'project' }
    $verb = if ($Added.Count -gt 0 -and $Modified.Count -eq 0 -and $Deleted.Count -eq 0) { 'feat' }
            elseif ($Deleted.Count -gt 0 -and $Modified.Count -eq 0 -and $Added.Count -eq 0) { 'chore' }
            else { 'update' }
    $detail = if ($all.Count -eq 1) { [IO.Path]::GetFileName($all[0]) } else { "$($all.Count) files" }
    $title = "${verb}(${scope}): update ${detail}"
    $source = 'local'
    if (-not [string]::IsNullOrWhiteSpace($AiSuggestion)) {
        $candidate = ($AiSuggestion -split '[\r\n]')[0].Trim()
        if ($candidate.Length -ge 8 -and $candidate.Length -le 100 -and $candidate -notmatch '[\x00-\x1f]') {
            $title = $candidate
            $source = 'ai'
        }
    }
    $summary = "Added: $($Added.Count); modified: $($Modified.Count); deleted: $($Deleted.Count)."
    [pscustomobject]@{
        Title = $title; Summary = $summary; HasChanges = $true
        Source = $source; Files = $all
    }
}
function Get-GangplankSmartSavePrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Diff)
    # Send only file paths/statuses; an approved AI adapter can add sanitized diffs.
    $entries = @()
    foreach ($type in @('New','Modified','Deleted')) {
        foreach ($path in @($Diff.$type)) {
            $entries += [pscustomobject]@{ status = $type; path = [string]$path }
        }
    }
    $payload = $entries | ConvertTo-Json -Depth 4 -Compress
    return "Write one concise imperative conventional commit title (max 72 characters). Do not invent behavior or tests. Changes: $payload"
}
