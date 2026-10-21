#Requires -Version 5.1
# Verified workspace operations: download baseline -> inspect -> select -> save.
# All writes are restricted to changed, explicitly selected files.

function Get-KeystoneRemoteHead {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [string]$Branch)
    if (-not $Branch) { $Branch = $Session.DefaultBranch }
    if ($Session.Provider -eq 'GitHub') {
        return $Session.ProviderObj.GetRefSha($Session.ProjectPath, $Branch)
    }
    $project = $Session.ProviderObj.EncodePath($Session.ProjectPath)
    $encoded = [uri]::EscapeDataString($Branch)
    $ref = $Session.ProviderObj.InvokeApi('GET', "projects/$project/repository/branches/$encoded")
    return [string]$ref.commit.id
}

function Get-KeystoneSafeWorkspacePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Branch)
    $folder = Get-KeystoneSafeName ($Project -replace '/', '-')
    $branchName = Get-KeystoneSafeName $Branch
    $path = Join-Path $Base (Join-Path $folder $branchName)
    if (Test-Path -LiteralPath $path) {
        $path = Join-Path $Base (Join-Path $folder ("$branchName-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,6))))
    }
    return $path
}

function Test-KeystoneSensitivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Replace('\','/').ToLowerInvariant()
    $name = ($p -split '/')[-1]
    if ($p -match '(^|/)(\.git|node_modules|logs|work|\.vs|\.venv|__pycache__)(/|$)') { return $true }
    if ($name -match '(^\.env($|\.)|^id_(rsa|ed25519)|^\.npmrc$|^\.pypirc$|^credentials($|\.)|^token($|\.)|\.p(12|fx|em|pk)$|\.key$|^secrets?\.json$)') { return $true }
    return $false
}

function Get-KeystoneWorkspacePreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    if (-not $Session.LocalPath -or -not (Test-Path -LiteralPath $Session.LocalPath -PathType Container)) {
        throw 'Download the project into a Keystone workspace first.'
    }
    if (-not $Session.BaselineSha) {
        throw 'This folder has no verified download baseline. Download the project again.'
    }
    $branch = if ($Session.LastBranch) { $Session.LastBranch } else { $Session.DefaultBranch }
    $remote = Get-KeystoneRemoteHead -Session $Session -Branch $branch
    $stale = ($remote -ne $Session.BaselineSha)
    $local = Get-KeystoneLocalFileMap -Root $Session.LocalPath
    $diff = Get-KeystonePathDiff -LocalMap $local -RemoteMap $Session.BaselineMap
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($kind in @('New','Modified','Deleted')) {
        foreach ($path in @($diff.$kind | Sort-Object)) {
            $blocked = Test-KeystoneSensitivePath -Path $path
            $size = 0
            if ($kind -ne 'Deleted') {
                $file = Join-Path $Session.LocalPath ($path.Replace('/',[IO.Path]::DirectorySeparatorChar))
                if (Test-Path -LiteralPath $file -PathType Leaf) { $size = (Get-Item -LiteralPath $file).Length }
                if ($size -gt 5242880) { $blocked = $true }
            }
            [void]$records.Add([pscustomobject]@{
                Path = $path; Kind = $kind; Size = $size
                Blocked = $blocked; Selected = (-not $blocked -and $kind -ne 'Deleted')
            })
        }
    }
    $active = @($records.ToArray() | Where-Object { $_.Selected })
    $msg = New-KeystoneSmartMessage -Added @($active | Where-Object { $_.Kind -eq 'New' } | ForEach-Object Path) -Modified @($active | Where-Object { $_.Kind -eq 'Modified' } | ForEach-Object Path) -Deleted @($active | Where-Object { $_.Kind -eq 'Deleted' } | ForEach-Object Path)
    return [pscustomobject]@{
        Project = $Session.ProjectPath; Provider = $Session.Provider; Branch = $branch
        LocalPath = $Session.LocalPath; BaselineSha = $Session.BaselineSha
        RemoteChanged = $stale; Changes = @($records.ToArray()); SmartMessage = $msg
    }
}

function Invoke-KeystoneWorkspaceSave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string[]]$SelectedPaths,
        [string]$Message
    )
    $preview = Get-KeystoneWorkspacePreview -Session $Session
    if ($preview.RemoteChanged) { throw 'The project changed online. No files were uploaded. Download a fresh workspace and reconcile your edits.' }
    $available = @{}
    foreach ($entry in @($preview.Changes)) { $available[$entry.Path] = $entry }
    $paths = @($SelectedPaths | Select-Object -Unique)
    if ($paths.Count -eq 0) { throw 'Select at least one file to save.' }
    foreach ($p in $paths) {
        if (-not $available.ContainsKey($p)) { throw "File is not a pending change: $p" }
        if ($available[$p].Blocked) { throw "File is excluded or too large: $p" }
    }
    $added = @($paths | Where-Object { $available[$_].Kind -eq 'New' })
    $modified = @($paths | Where-Object { $available[$_].Kind -eq 'Modified' })
    $deleted = @($paths | Where-Object { $available[$_].Kind -eq 'Deleted' })
    $suggestion = New-KeystoneSmartMessage -Added $added -Modified $modified -Deleted $deleted
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = $suggestion.Title }
    if ($Message.Length -gt 160 -or $Message -match '[\r\n]') { throw 'Commit message must be a single line under 160 characters.' }
    $branch = $preview.Branch
    $head = Get-KeystoneRemoteHead -Session $Session -Branch $branch
    if ($head -ne $Session.BaselineSha) { throw 'Remote branch changed. Save cancelled before upload.' }

    $root = [IO.Path]::GetFullPath($Session.LocalPath).TrimEnd('\','/')
    if ($Session.Provider -eq 'GitHub') {
        $provider = $Session.ProviderObj
        $prior = $provider.InvokeApi('GET', "repos/$($Session.ProjectPath)/git/commits/$head")
        $treeItems = New-Object System.Collections.Generic.List[object]
        foreach ($p in $paths) {
            if ($available[$p].Kind -eq 'Deleted') {
                [void]$treeItems.Add(@{ path = $p; mode = '100644'; type = 'blob'; sha = $null })
                continue
            }
            $full = [IO.Path]::GetFullPath((Join-Path $root ($p.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if (-not $full.StartsWith(($root + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe file path.' }
            $item = Get-Item -LiteralPath $full
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked files are not supported: $p" }
            if ($item.Length -gt 5242880) { throw "File grew beyond 5 MB: $p" }
            $sha = $provider.CreateBlob($Session.ProjectPath,[IO.File]::ReadAllBytes($full))
            [void]$treeItems.Add(@{ path = $p; mode = '100644'; type = 'blob'; sha = $sha })
        }
        $tree = $provider.CreateTree($Session.ProjectPath,$treeItems.ToArray(),[string]$prior.tree.sha)
        $commit = $provider.CreateCommit($Session.ProjectPath,$Message,$tree,@($head))
        # Force is prohibited. Concurrent updates cause a non-fast-forward rejection.
        $provider.CreateOrUpdateBranchRef($Session.ProjectPath,$branch,$commit,$false)
        $newHead = $commit
    } elseif ($Session.Provider -eq 'GitLab') {
        $provider = $Session.ProviderObj
        $actions = New-Object System.Collections.Generic.List[object]
        foreach ($p in $paths) {
            if ($available[$p].Kind -eq 'Deleted') {
                [void]$actions.Add(@{ action = 'delete'; file_path = $p })
                continue
            }
            $full = [IO.Path]::GetFullPath((Join-Path $root ($p.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if (-not $full.StartsWith(($root + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe file path.' }
            $item = Get-Item -LiteralPath $full
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked files are not supported: $p" }
            if ($item.Length -gt 5242880) { throw "File grew beyond 5 MB: $p" }
            [void]$actions.Add(@{
                action = $(if ($available[$p].Kind -eq 'New') { 'create' } else { 'update' })
                file_path = $p; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($full)); encoding = 'base64'
            })
        }
        $project = $provider.EncodePath($Session.ProjectPath)
        $payload = @{ branch = $branch; commit_message = $Message; actions = @($actions.ToArray()) }
        # GitLab update/delete actions should supply last_commit_id for stricter per-file protection.
        foreach ($a in $payload.actions) {
            if ($a.action -ne 'create') { $a.last_commit_id = $head }
        }
        $result = $provider.InvokeApi('POST',"projects/$project/repository/commits",$payload)
        $newHead = [string]$result.id
    } else {
        throw 'Provider is not supported.'
    }
    # Update baseline only for the selected files. Remaining edits stay pending.
    foreach ($p in $paths) {
        if ($available[$p].Kind -eq 'Deleted') {
            $Session.BaselineMap.Remove($p)
        } else {
            $full = Join-Path $root ($p.Replace('/',[IO.Path]::DirectorySeparatorChar))
            $Session.BaselineMap[$p] = Get-KeystoneFileSha256 -Path $full
        }
    }
    $Session.BaselineSha = $newHead
    return [pscustomobject]@{
        Saved = $true; Commit = $newHead; Message = $Message; FileCount = $paths.Count
        Url = $(if ($Session.Provider -eq 'GitHub') { "https://github.com/$($Session.ProjectPath)/commit/$newHead" } else { "$($Session.BaseUrl)/$($Session.ProjectPath)/-/commit/$newHead" })
    }
}
