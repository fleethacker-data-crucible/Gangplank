#Requires -Version 5.1
# Use an existing folder as the workspace, instead of downloading a fresh copy.
#   - A git clone: the branch and commit are read from .git\HEAD (and refs\heads or
#     packed-refs). No git.exe. The folder's files are compared with the project at that commit.
#   - A plain folder (no .git): matched to the head of a branch. At least one file must be
#     identical, so a folder that is not this project is refused.
# The baseline is always the project's own files at that commit (from the archive), so the
# local edits show up as changes exactly as they do in a downloaded workspace. Nothing in the
# folder is changed, and nothing is uploaded.

function Read-GangplankCloneHead {
    # @{ Branch; Sha } for a git clone folder, or $null (no .git, a linked work tree, or an
    # unreadable HEAD). Reads plain files only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder)
    $gitDir = Join-Path $Folder '.git'
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) { return $null }
    $headFile = Join-Path $gitDir 'HEAD'
    if (-not (Test-Path -LiteralPath $headFile -PathType Leaf)) { return $null }
    $head = ([IO.File]::ReadAllText($headFile)).Trim()
    if ($head -match '^[0-9a-f]{40}$') { return @{ Branch = $null; Sha = $head } }     # detached HEAD
    if ($head -notmatch '^ref:\s*refs/heads/(.+)$') { return $null }
    $branch = $Matches[1].Trim()
    if ($branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $branch -match '(\.\.|//|\.lock$)') { return $null }
    $sha = $null
    $refFile = Join-Path $gitDir ('refs\heads\' + $branch.Replace('/','\'))
    if (Test-Path -LiteralPath $refFile -PathType Leaf) { $sha = ([IO.File]::ReadAllText($refFile)).Trim() }
    if (-not $sha -or $sha -notmatch '^[0-9a-f]{40}$') {
        $packed = Join-Path $gitDir 'packed-refs'
        $sha = $null
        if (Test-Path -LiteralPath $packed -PathType Leaf) {
            foreach ($line in [IO.File]::ReadAllLines($packed)) {
                if ($line -match '^([0-9a-f]{40}) refs/heads/(.+)$' -and $Matches[2].Trim() -ceq $branch) { $sha = $Matches[1]; break }
            }
        }
    }
    if (-not $sha) { return $null }
    return @{ Branch = $branch; Sha = $sha }
}

function Add-GangplankExistingFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][AllowEmptyString()][string]$Folder,[string]$Branch)
    if ([string]::IsNullOrWhiteSpace($Folder) -or $Folder.Length -gt 500 -or $Folder -match '[\x00-\x1f]') { throw 'BAD_REQUEST|Enter the full path of the folder.' }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw 'NOT_FOUND|That folder was not found.' }
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\','/')
    if ($full.Length -le 3 -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')) { throw 'BAD_REQUEST|Choose a project folder, not a whole drive.' }
    if (((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'BAD_REQUEST|Linked folders are not supported. Enter the real folder path.' }

    $clone = Read-GangplankCloneHead -Folder $full
    if ($clone) {
        $source = 'git clone'
        $branchName = $clone.Branch
        if (-not $branchName) { throw 'BAD_STATE|This clone is not on a branch (detached HEAD). Switch it to a branch with your usual Git tool first.' }
        $sha = [string]$clone.Sha
    } else {
        $source = 'plain folder'
        $branchName = if ($Branch) { $Branch.Trim() } elseif ($Session.LastBranch) { [string]$Session.LastBranch } else { [string]$Session.DefaultBranch }
        if ($branchName.Length -gt 200 -or $branchName -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $branchName -match '(\.\.|//)') { throw 'BAD_REQUEST|Branch name is not valid.' }
        $sha = $null
    }
    $head = Get-GangplankRemoteHead -Session $Session -Branch $branchName
    if (-not $head) { throw "NOT_FOUND|The branch '$branchName' is not on the project online. Push it with your usual Git tool first, or choose another branch." }
    if (-not $sha) { $sha = [string]$head }

    $archive = $null
    try { $archive = Expand-GangplankArchiveAt -Session $Session -Sha $sha }
    catch {
        if ($clone -and [string]$_.Exception.Message -match '^(NOT_FOUND|CONFLICT|HTTP_4\d\d)\|') {
            throw 'NOT_FOUND|This clone is at a commit that is not online yet (unpushed work). Push it with your usual Git tool first.'
        }
        throw
    }
    try {
        $remoteMap = Get-GangplankLocalFileMap -Root $archive.Root
    } finally {
        Remove-Item -LiteralPath $archive.Cleanup -Recurse -Force -ErrorAction SilentlyContinue
    }
    $localMap = Get-GangplankLocalFileMap -Root $full
    $same = 0; $modified = 0; $new = 0
    foreach ($k in $localMap.Keys) {
        if (-not $remoteMap.ContainsKey($k)) { $new++ }
        elseif ([string]$remoteMap[$k] -ceq [string]$localMap[$k]) { $same++ }
        else { $modified++ }
    }
    $missing = @($remoteMap.Keys | Where-Object { -not $localMap.ContainsKey($_) }).Count
    if (-not $clone -and $remoteMap.Count -gt 0 -and $same -eq 0) {
        throw "BAD_REQUEST|This folder does not look like a copy of $($Session.ProjectPath): none of its files match the branch '$branchName'."
    }

    $Session.LocalPath = $full
    $Session.LastBranch = $branchName
    $Session.BaselineSha = $sha
    $Session.BaselineMap = $remoteMap
    Write-GangplankAudit -Action 'workspace.adopted' -Data @{
        provider = $Session.Provider; project = $Session.ProjectPath; branch = $branchName; sha = $sha
        source = $source; folder = $full; same = $same; modified = $modified; added = $new; missing = $missing
    }
    return [pscustomobject]@{
        Folder = $full; Branch = $branchName; Sha = $sha; Source = $source
        Same = $same; Modified = $modified; New = $new; Missing = $missing
        Behind = ($sha -ne [string]$head); OnDefaultBranch = ($branchName -ceq [string]$Session.DefaultBranch)
    }
}
