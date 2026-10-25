#Requires -Version 5.1
# Verified workspace operations: download baseline -> inspect -> select -> save.

function Assert-KeystoneTrustedRepositoryUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri)) { throw 'Enter a complete HTTPS GitHub or GitLab project URL.' }
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Port -ne 443) { throw 'Only standard HTTPS project URLs without embedded credentials are supported.' }
    $hosts = @('github.com','web.git.mil')
    if ($env:KEYSTONE_GITLAB_ALLOWED_HOSTS) {
        $hosts += @($env:KEYSTONE_GITLAB_ALLOWED_HOSTS -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    if ($uri.Host.ToLowerInvariant() -notin $hosts) {
        throw 'Repository host not allowlisted. Ask an administrator to set KEYSTONE_GITLAB_ALLOWED_HOSTS for approved self-hosted GitLab.'
    }
    if ($uri.Host -eq 'github.com' -and @($uri.AbsolutePath.Trim('/') -split '/').Count -lt 2) { throw 'GitHub project URL needs an owner and repository.' }
    if ($uri.AbsolutePath.Trim('/') -eq '') { throw 'Repository path is missing.' }
}
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

function New-KeystoneWorkBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[string]$Name)
    $base = $Session.DefaultBranch
    $head = Get-KeystoneRemoteHead -Session $Session -Branch $base
    if (-not $head) { throw 'The default branch has no commit. Initialize this repository through the provider first.' }
    if (-not $Name) { $Name = 'keystone/work-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,6)) }
    if ($Name.Length -gt 100 -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]+$' -or $Name -match '(\.\.|//|@{|/\.|\.lock($|/)|/$)') {
        throw 'Invalid work branch name.'
    }
    if ($Session.Provider -eq 'GitHub') {
        $payload = @{ ref = "refs/heads/$Name"; sha = $head }
        [void]$Session.ProviderObj.InvokeApi('POST',"repos/$($Session.ProjectPath)/git/refs",$payload)
    } elseif ($Session.Provider -eq 'GitLab') {
        $project = $Session.ProviderObj.EncodePath($Session.ProjectPath)
        $payload = @{ branch = $Name; ref = $base }
        [void]$Session.ProviderObj.InvokeApi('POST',"projects/$project/repository/branches",$payload)
    } else { throw 'Unsupported provider.' }
    $Session.LastBranch = $Name
    $Session.BaselineSha = $null
    $Session.BaselineMap = @{}
    $Session.LocalPath = $null
    return $Name
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

function Test-KeystoneSecretContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 5242880) { return $true }
    if ($file.Extension.ToLowerInvariant() -notin @('.txt','.ps1','.psm1','.json','.yaml','.yml','.py','.js','.ts','.cs','.html','.xml','.config','.properties','.md','.sh','.bat','.cmd','.env')) { return $false }
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -match '-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----') { return $true }
    if ($text -match '\b(?:gh[pousr]_[A-Za-z0-9_]{24,}|github_pat_[A-Za-z0-9_]{24,}|(?:AKIA|ASIA)[0-9A-Z]{16})\b') { return $true }
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
                elseif (Test-KeystoneSecretContent -Path $file) { $blocked = $true }
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
        [string]$Message,
        [switch]$PublicConfirmed
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
    # Fail closed before any remote write; publication is not public-release authorization.
    $scanPaths = @($paths | Where-Object { $available[$_].Kind -ne 'Deleted' })
    $sentinel = Test-KeystoneSentinelPublication -Session $Session -Paths $scanPaths
    if (-not $sentinel.Allowed) {
        $codes = @($sentinel.Findings | Where-Object { $_.Severity -in @('Block','Review') } | ForEach-Object Code | Select-Object -Unique)
        throw ('Sentinel blocked publication: ' + ($codes -join ', '))
    }
    if ($sentinel.RequiresPublicConfirmation) {
        if ($env:KEYSTONE_ALLOW_PUBLIC_PUBLISH -ne '1') {
            throw 'Sentinel blocks public publishing by default. Administrator approval and KEYSTONE_ALLOW_PUBLIC_PUBLISH=1 required.'
        }
        if (-not $PublicConfirmed) {
            throw 'Public repository detected. Explicit public-publish confirmation is required.'
        }
    }
    $added = @($paths | Where-Object { $available[$_].Kind -eq 'New' })
    $modified = @($paths | Where-Object { $available[$_].Kind -eq 'Modified' })
    $deleted = @($paths | Where-Object { $available[$_].Kind -eq 'Deleted' })
    $suggestion = New-KeystoneSmartMessage -Added $added -Modified $modified -Deleted $deleted
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = $suggestion.Title }
    if ($Message.Length -gt 160 -or $Message -match '[\r\n]') { throw 'Commit message must be a single line under 160 characters.' }
    $branch = $preview.Branch
    if ($branch -eq $Session.DefaultBranch -and $env:KEYSTONE_ALLOW_DEFAULT_BRANCH_WRITES -ne '1') {
        throw 'Direct saves to the default branch are disabled. Create a work branch from the browser before saving.'
    }
    $head = Get-KeystoneRemoteHead -Session $Session -Branch $branch
    if ($head -ne $Session.BaselineSha) { throw 'Remote branch changed. Save cancelled before upload.' }

    $root = [IO.Path]::GetFullPath($Session.LocalPath).TrimEnd('\','/')
    if ($Session.Provider -eq 'GitHub') {
        $provider = $Session.ProviderObj
        $prior = $provider.InvokeApi('GET', "repos/$($Session.ProjectPath)/git/commits/$head")
        # Keep each modified file's existing Git mode (an executable script stays
        # 100755). New files get the regular-file mode.
        $modified = @($paths | Where-Object { $available[$_].Kind -eq 'Modified' })
        $modes = @{}
        if ($modified.Count -gt 0) { $modes = $provider.GetPathModes($Session.ProjectPath,[string]$prior.tree.sha,$modified) }
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
            if (Test-KeystoneSecretContent -Path $full) { throw "Potential secret detected. File not uploaded: $p" }
            $sha = $provider.CreateBlob($Session.ProjectPath,[IO.File]::ReadAllBytes($full))
            $mode = if ($modes.ContainsKey($p)) { [string]$modes[$p] } else { '100644' }
            [void]$treeItems.Add(@{ path = $p; mode = $mode; type = 'blob'; sha = $sha })
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
            if (Test-KeystoneSecretContent -Path $full) { throw "Potential secret detected. File not uploaded: $p" }
            [void]$actions.Add(@{
                action = $(if ($available[$p].Kind -eq 'New') { 'create' } else { 'update' })
                file_path = $p; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($full)); encoding = 'base64'
            })
        }
        $project = $provider.EncodePath($Session.ProjectPath)
        $payload = @{ branch = $branch; commit_message = $Message; actions = @($actions.ToArray()) }
        # GitLab needs the last commit that touched EACH file, not the branch tip.
        foreach ($a in $payload.actions) {
            if ($a.action -eq 'create') { continue }
            $filePath = ($a.file_path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '%2F'
            $encodedBranch = [uri]::EscapeDataString($branch)
            $metadata = $provider.InvokeApi('GET',"projects/$project/repository/files/$filePath" + "?ref=$encodedBranch")
            if (-not $metadata.last_commit_id) { throw "Cannot verify last modification for $($a.file_path)." }
            $a.last_commit_id = [string]$metadata.last_commit_id
        }
        # One last HEAD check before publishing this batch.
        if ((Get-KeystoneRemoteHead -Session $Session -Branch $branch) -ne $head) { throw 'The remote branch changed while preparing the save.' }
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
