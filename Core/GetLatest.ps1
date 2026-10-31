#Requires -Version 5.1
# Get latest: bring changes made online since the download into the open workspace.
# A three-way comparison of the download baseline, the local files and the newest commit:
#   - changed only online          -> applied automatically
#   - changed the same way in both -> nothing to do
#   - changed in both, differently -> an overlap: nothing is touched until every overlap
#                                     has a choice ("mine" or "theirs")
# "theirs" saves the local copy aside first (see Save-GangplankWorkspaceBackup). "mine" keeps
# the local file and records the online version as the new baseline, so the file shows as a
# change that Smart Save would publish on purpose. Nothing is forced and nothing is deleted
# without a copy being kept when the local file differed.

function Get-GangplankMapValue {
    param($Map,[string]$Key)
    if ($Map -and $Map.ContainsKey($Key)) { return [string]$Map[$Key] }
    return $null
}

function Get-GangplankChangeLabel {
    # How a file differs from the baseline: added, deleted or changed.
    param($Baseline,$Now)
    if ($null -eq $Now) { return 'deleted' }
    if ($null -eq $Baseline) { return 'added' }
    return 'changed'
}

function Update-GangplankWorkspaceFromRemote {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[hashtable]$Choices = @{})
    if (-not $Session.LocalPath -or -not (Test-Path -LiteralPath $Session.LocalPath -PathType Container)) { throw 'BAD_STATE|Download the project into a Gangplank workspace first.' }
    if (-not $Session.BaselineSha) { throw 'BAD_STATE|This folder has no verified download baseline. Download the project again.' }
    $branch = if ($Session.LastBranch) { [string]$Session.LastBranch } else { [string]$Session.DefaultBranch }
    $head = Get-GangplankRemoteHead -Session $Session -Branch $branch
    if (-not $head) { throw 'NOT_FOUND|That branch no longer exists online.' }
    if ($head -eq $Session.BaselineSha) {
        return [pscustomobject]@{ UpToDate = $true; NeedsChoice = $false; Applied = @(); Overlaps = @(); Head = $head }
    }
    foreach ($k in @($Choices.Keys)) {
        [void](ConvertTo-GangplankSafeRelativePath -Path ([string]$k))
        if ([string]$Choices[$k] -notin @('mine','theirs')) { throw 'BAD_REQUEST|Choose "mine" or "theirs" for each file.' }
    }

    $archive = Expand-GangplankArchiveAt -Session $Session -Sha $head
    try {
        $base = $Session.BaselineMap
        $mine = Get-GangplankLocalFileMap -Root $Session.LocalPath
        $theirs = Get-GangplankLocalFileMap -Root $archive.Root
        $paths = @(@($base.Keys) + @($mine.Keys) + @($theirs.Keys) | Sort-Object -Unique)

        $changedOnline = New-Object System.Collections.Generic.List[string]
        $apply = New-Object System.Collections.Generic.List[object]      # @{ Path; Backup }
        $keep = New-Object System.Collections.Generic.List[string]
        $overlaps = New-Object System.Collections.Generic.List[object]
        $unresolved = 0
        foreach ($p in $paths) {
            $b = Get-GangplankMapValue $base $p; $m = Get-GangplankMapValue $mine $p; $t = Get-GangplankMapValue $theirs $p
            if ($t -ceq $b) { continue }                      # not changed online
            [void]$changedOnline.Add($p)
            if ($m -ceq $t) { continue }                      # already the same here
            if ($m -ceq $b) { [void]$apply.Add(@{ Path = $p; Backup = $false }); continue }   # only changed online
            $choice = if ($Choices.ContainsKey($p)) { [string]$Choices[$p] } else { '' }
            [void]$overlaps.Add([pscustomobject]@{ path = $p; online = (Get-GangplankChangeLabel $b $t); yours = (Get-GangplankChangeLabel $b $m); choice = $choice })
            if ($choice -eq 'theirs') { [void]$apply.Add(@{ Path = $p; Backup = $true }) }
            elseif ($choice -eq 'mine') { [void]$keep.Add($p) }
            else { $unresolved++ }
        }
        if ($unresolved -gt 0) {
            # Ask first: no file is touched until every overlap has a choice.
            return [pscustomobject]@{ UpToDate = $false; NeedsChoice = $true; Applied = @(); Overlaps = @($overlaps.ToArray()); Head = $head }
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $applied = New-Object System.Collections.Generic.List[object]
        foreach ($a in $apply) {
            $p = [string]$a.Path
            $dst = Resolve-GangplankWorkspaceFile -Root $Session.LocalPath -RelativePath $p
            if ($a.Backup) { [void](Save-GangplankWorkspaceBackup -Session $Session -RelativePath $p -Stamp $stamp) }
            if ($theirs.ContainsKey($p)) {
                $src = Resolve-GangplankWorkspaceFile -Root $archive.Root -RelativePath $p
                $dir = Split-Path $dst -Parent
                if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                $existed = Test-Path -LiteralPath $dst
                Copy-Item -LiteralPath $src -Destination $dst -Force
                [void]$applied.Add([pscustomobject]@{ path = $p; action = $(if ($existed) { 'updated' } else { 'added' }) })
            } else {
                if (Test-Path -LiteralPath $dst -PathType Leaf) { Remove-Item -LiteralPath $dst -Force }
                [void]$applied.Add([pscustomobject]@{ path = $p; action = 'removed' })
            }
        }
        foreach ($p in $keep) { [void]$applied.Add([pscustomobject]@{ path = $p; action = 'kept yours' }) }

        # The online version is the new baseline for every file that changed online.
        foreach ($p in $changedOnline) {
            if ($theirs.ContainsKey($p)) { $base[$p] = $theirs[$p] } else { $base.Remove($p) }
        }
        $previous = [string]$Session.BaselineSha
        $Session.BaselineMap = $base
        $Session.BaselineSha = $head
        Write-GangplankAudit -Action 'workspace.updated' -Data @{
            provider = $Session.Provider; project = $Session.ProjectPath; branch = $branch; from = $previous; to = $head
            updated = $apply.Count; keptYours = $keep.Count
        }
        return [pscustomobject]@{ UpToDate = $false; NeedsChoice = $false; Applied = @($applied.ToArray()); Overlaps = @($overlaps.ToArray()); Head = $head }
    } finally {
        Remove-Item -LiteralPath $archive.Cleanup -Recurse -Force -ErrorAction SilentlyContinue
    }
}
