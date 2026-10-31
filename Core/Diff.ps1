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
