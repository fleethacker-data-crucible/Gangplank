#Requires -Version 5.1
# ============================================================
#  Core/Diff.ps1 - local vs remote file maps and push actions
# ============================================================

function Get-GangplankFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-GangplankLocalFileMap {
    param(
        [string]$Root,
        [string[]]$ExcludeDirNames = @("Logs", "work", ".git", ".vs", "node_modules")
    )
    $map = @{}
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $map }
    $exclude = @{}
    foreach ($d in $ExcludeDirNames) { $exclude[$d.ToLowerInvariant()] = $true }
    $prefix = $Root.TrimEnd('\', '/')
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $relDir = $_.DirectoryName.Substring($prefix.Length).TrimStart('\', '/').Replace('\', '/')
        $skip = $false
        foreach ($p in ($relDir -split '/')) {
            if ($p -and $exclude.ContainsKey($p.ToLowerInvariant())) { $skip = $true; break }
        }
        if ($skip) { return }
        $rel = $_.FullName.Substring($prefix.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel) {
            $map[$rel] = (Get-GangplankFileSha256 $_.FullName)
        }
    }
    return $map
}

function Get-GangplankRemoteMapFromZip {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $map = @{}
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $top = $null
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $name = $entry.FullName.Replace('\', '/')
            if (-not $top) {
                $parts = $name -split '/'
                if ($parts.Count -gt 1) { $top = $parts[0] + '/' }
            }
            if ($top -and $name.StartsWith($top)) {
                $name = $name.Substring($top.Length)
            }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $stream = $entry.Open()
            try {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $hash = $sha.ComputeHash($stream)
                    $map[$name] = ([BitConverter]::ToString($hash) -replace '-', '')
                } finally { $sha.Dispose() }
            } finally { $stream.Dispose() }
        }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
    return $map
}

function Get-GangplankPathDiff {
    param([hashtable]$LocalMap, [hashtable]$RemoteMap)
    if (-not $LocalMap) { $LocalMap = @{} }
    if (-not $RemoteMap) { $RemoteMap = @{} }
    $new = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $deleted = New-Object System.Collections.Generic.List[string]
    foreach ($key in $LocalMap.Keys) {
        if (-not $RemoteMap.ContainsKey($key)) { [void]$new.Add($key) }
        elseif ("$($LocalMap[$key])" -ne "$($RemoteMap[$key])") { [void]$modified.Add($key) }
    }
    foreach ($key in $RemoteMap.Keys) {
        if (-not $LocalMap.ContainsKey($key)) { [void]$deleted.Add($key) }
    }
    return [PSCustomObject]@{
        New      = @($new)
        Modified = @($modified)
        Deleted  = @($deleted)
    }
}

function New-GangplankPushActions {
    param(
        [string]$LocalPath,
        $Diff,
        [ValidateSet("Include", "Omit")]
        [string]$DeletePolicy = "Omit"
    )
    $actions = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($Diff.New)) {
        $full = Join-Path $LocalPath ($f -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $bytes = [IO.File]::ReadAllBytes($full)
        [void]$actions.Add([PSCustomObject]@{
            action    = "create"
            file_path = $f
            content   = [Convert]::ToBase64String($bytes)
            encoding  = "base64"
        })
    }
    foreach ($f in @($Diff.Modified)) {
        $full = Join-Path $LocalPath ($f -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $bytes = [IO.File]::ReadAllBytes($full)
        [void]$actions.Add([PSCustomObject]@{
            action    = "update"
            file_path = $f
            content   = [Convert]::ToBase64String($bytes)
            encoding  = "base64"
        })
    }
    if ($DeletePolicy -eq "Include") {
        foreach ($f in @($Diff.Deleted)) {
            [void]$actions.Add([PSCustomObject]@{
                action    = "delete"
                file_path = $f
            })
        }
    }
    return @($actions)
}

function Split-GangplankPushBatches {
    param(
        $Actions,
        [string]$Branch,
        [string]$Message,
        [int]$MaxBytes = 10485760
    )
    $list = @($Actions)
    if ($list.Count -eq 0) { return @() }
    $batches = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[object]
    foreach ($action in $list) {
        $trial = @($current) + @($action)
        $body = @{ branch = $Branch; commit_message = $Message; actions = $trial }
        $json = $body | ConvertTo-Json -Depth 8 -Compress
        $bytes = [Text.Encoding]::UTF8.GetByteCount($json)
        if ($current.Count -gt 0 -and $bytes -gt $MaxBytes) {
            [void]$batches.Add(@($current.ToArray()))
            $current = New-Object System.Collections.Generic.List[object]
        }
        [void]$current.Add($action)
    }
    if ($current.Count -gt 0) { [void]$batches.Add(@($current.ToArray())) }
    return @($batches)
}


# ---------------------------------------------------------------------------
# Diff viewer (roadmap 10): the text of one pending change, before and after.
# The line diff itself is computed in the browser (web/diff-worker.js); the host
# only fetches the two texts, with the same exclusions Smart Save applies.
# ---------------------------------------------------------------------------
$script:GangplankDiffMaxBytes = 524288

function ConvertFrom-GangplankDiffBytes {
    # One side of a diff as text. A NUL byte in the first 8 KB means binary: no text is returned.
    param([byte[]]$Bytes,[int]$MaxBytes = 524288)
    if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }
    if ($Bytes.Length -gt $MaxBytes) { return @{ Found = $true; Size = $Bytes.Length; TooLarge = $true; Binary = $false; Text = '' } }
    $nul = [Array]::IndexOf($Bytes,[byte]0)
    if ($nul -ge 0 -and $nul -lt 8000) { return @{ Found = $true; Size = $Bytes.Length; TooLarge = $false; Binary = $true; Text = '' } }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($Bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return @{ Found = $true; Size = $Bytes.Length; TooLarge = $false; Binary = $false; Text = $text }
}

function ConvertFrom-GangplankFileContent {
    # A file as GitHub's Contents API or GitLab's repository files API describes it
    # ({ type; size; encoding; content }, base64) -> the same shape as ConvertFrom-GangplankDiffBytes.
    param($Item,[int]$MaxBytes = 524288)
    if ($null -eq $Item -or $Item -is [array]) { return @{ Found = $false } }
    $type = 'file'
    if ($Item.PSObject.Properties['type']) { $type = [string]$Item.type }
    if ($type -ne 'file') { return @{ Found = $true; Size = 0; TooLarge = $false; Binary = $true; Text = '' } }   # link or submodule
    $size = [int64]0
    if ($Item.PSObject.Properties['size']) { $size = [int64]$Item.size }
    $encoding = ''
    if ($Item.PSObject.Properties['encoding']) { $encoding = [string]$Item.encoding }
    # GitHub sends no content above 1 MB (encoding "none"); the cap is lower than that anyway.
    if ($size -gt $MaxBytes -or $encoding -ne 'base64') { return @{ Found = $true; Size = $size; TooLarge = $true; Binary = $false; Text = '' } }
    $bytes = [Convert]::FromBase64String(([string]$Item.content) -replace '\s','')
    return (ConvertFrom-GangplankDiffBytes -Bytes $bytes -MaxBytes $MaxBytes)
}

function Get-GangplankFileDiff {
    # GET /api/diff: { path; kind; binary; truncated; excluded; limit; before; after } for one
    # pending change. Only paths Get-GangplankWorkspacePreview lists are served; files Smart
    # Save would exclude (secrets, oversize) are never read.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1000 -or $Path -match '[\x00-\x1f\\]' -or $Path.StartsWith('/') -or $Path -match '^[A-Za-z]:' -or $Path -match '(^|/)\.\.?(/|$)') {
        throw 'BAD_REQUEST|Choose a changed file from the list.'
    }
    $max = [int]$script:GangplankDiffMaxBytes
    $preview = Get-GangplankWorkspacePreview -Session $Session
    $change = @($preview.Changes | Where-Object { $_.Path -ceq $Path })[0]
    if (-not $change) { throw 'NOT_FOUND|That file is not a pending change.' }
    $result = [ordered]@{ path = [string]$change.Path; kind = [string]$change.Kind; binary = $false; truncated = $false; excluded = $false; limit = $max; before = ''; after = '' }
    if ($change.Blocked) { $result.excluded = $true; return $result }

    if ($change.Kind -ne 'Deleted') {
        $root = [IO.Path]::GetFullPath($Session.LocalPath).TrimEnd('\','/')
        $full = [IO.Path]::GetFullPath((Join-Path $root ($Path.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        if (-not $full.StartsWith(($root + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'BAD_REQUEST|Unsafe file path.' }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'NOT_FOUND|That file is no longer in the workspace. Refresh the list.' }
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.excluded = $true; return $result }
        if ($item.Length -gt $max) { $result.truncated = $true } else {
            $side = ConvertFrom-GangplankDiffBytes -Bytes ([IO.File]::ReadAllBytes($full)) -MaxBytes $max
            if ($side.Binary) { $result.binary = $true } elseif ($side.TooLarge) { $result.truncated = $true } else { $result.after = $side.Text }
        }
    }
    if ($change.Kind -ne 'New' -and -not $result.binary -and -not $result.truncated) {
        $side = $Session.ProviderObj.GetFileText([string]$Session.ProjectPath,[string]$Session.BaselineSha,[string]$Path,$max)
        if ($side.Found) {
            if ($side.Binary) { $result.binary = $true } elseif ($side.TooLarge) { $result.truncated = $true } else { $result.before = $side.Text }
        }
    }
    if ($result.binary -or $result.truncated) { $result.before = ''; $result.after = '' }
    return $result
}
