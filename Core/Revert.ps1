#Requires -Version 5.1
# Revert one file to the version that was downloaded (the workspace baseline).
# Only a pending change that already exists on the project can be reverted; a new file has
# nothing to go back to. The edited copy is saved aside first, and the earlier version must
# match the baseline hash recorded when the workspace was downloaded.

function Restore-GangplankWorkspaceFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $Path = ConvertTo-GangplankSafeRelativePath -Path $Path
    $preview = Get-GangplankWorkspacePreview -Session $Session
    $change = @($preview.Changes | Where-Object { $_.Path -ceq $Path })[0]
    if (-not $change) { throw 'NOT_FOUND|That file is not a pending change.' }
    if ($change.Kind -eq 'New') { throw 'BAD_STATE|This file is new, so there is no earlier version to go back to. Delete it from the folder if you do not want it.' }
    $expected = [string]$Session.BaselineMap[$Path]
    $backup = $null
    $archive = Expand-GangplankArchiveAt -Session $Session -Sha ([string]$Session.BaselineSha)
    try {
        $source = Resolve-GangplankWorkspaceFile -Root $archive.Root -RelativePath $Path
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'NOT_FOUND|The earlier version of this file is not in the project archive.' }
        if ((Get-GangplankFileSha256 -Path $source) -ne $expected) { throw 'BAD_STATE|The earlier version does not match what was downloaded. Download the project again.' }
        $backup = Save-GangplankWorkspaceBackup -Session $Session -RelativePath $Path -Stamp (Get-Date -Format 'yyyyMMdd-HHmmss')
        $target = Resolve-GangplankWorkspaceFile -Root $Session.LocalPath -RelativePath $Path
        $dir = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-Item -LiteralPath $source -Destination $target -Force
    } finally {
        Remove-Item -LiteralPath $archive.Cleanup -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-GangplankAudit -Action 'file.reverted' -Data @{
        provider = $Session.Provider; project = $Session.ProjectPath; branch = $preview.Branch
        path = $Path; kind = [string]$change.Kind; backedUp = [bool]$backup
    }
    return [pscustomobject]@{ Path = $Path; Kind = [string]$change.Kind; BackupPath = $backup }
}
