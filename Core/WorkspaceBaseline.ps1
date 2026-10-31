#Requires -Version 5.1
# Shared by revert, get latest and adopt: safe relative paths, the project as it was at one
# commit (the archive), and aside-copies of local edits before Gangplank replaces them.
# No git.exe: a commit's files come from the provider's archive.

function ConvertTo-GangplankSafeRelativePath {
    # A path inside the project, written with forward slashes. Refuses absolute paths,
    # drive letters, backslashes, control characters and .. segments.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1000 -or $Path -match '[\x00-\x1f\\]' -or $Path.StartsWith('/') -or $Path -match '^[A-Za-z]:' -or $Path -match '(^|/)\.\.?(/|$)') {
        throw 'BAD_REQUEST|Choose a file from the list.'
    }
    return $Path
}

function Resolve-GangplankWorkspaceFile {
    # Full path of a file under a root. Refuses a path outside the root and any link
    # (junction or symlink) between the root and the file.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$RelativePath)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull ($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if (-not $full.StartsWith(($rootFull + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'BAD_REQUEST|Unsafe file path.' }
    $probe = $full
    while ($probe.Length -gt $rootFull.Length) {
        if (Test-Path -LiteralPath $probe) {
            if (((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "BAD_REQUEST|Linked files are not supported: $RelativePath" }
        }
        $probe = Split-Path $probe -Parent
    }
    return $full
}

function Save-GangplankWorkspaceBackup {
    # Copy a local file aside, in <workspace>.gangplank-backup\<stamp>\ (outside the workspace, so it is
    # never listed as a change), before it is replaced. Returns the copy's path, or $null if there is no file.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Stamp)
    $src = Resolve-GangplankWorkspaceFile -Root $Session.LocalPath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return $null }
    $backupRoot = [IO.Path]::GetFullPath($Session.LocalPath).TrimEnd('\','/') + '.gangplank-backup'
    $dest = Join-Path (Join-Path $backupRoot $Stamp) ($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))
    $dir = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Copy-Item -LiteralPath $src -Destination $dest -Force
    return $dest
}

function Expand-GangplankArchiveAt {
    # Download the project archive at one commit and unpack it to a new temp folder.
    # Returns @{ Root = <the project files>; Cleanup = <folder to delete when done> }.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Sha)
    $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-{0}.zip' -f [guid]::NewGuid().ToString('N'))
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-ex-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $Session.ProviderObj.DownloadArchive($Session.ProjectPath,$Sha,$tmpZip)
        if (-not (Test-Path -LiteralPath $tmpZip) -or (Get-Item -LiteralPath $tmpZip).Length -eq 0) { throw 'NOT_FOUND|The project archive was empty.' }
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
        $roots = @(Get-ChildItem -LiteralPath $tmpDir -Force)
        $src = if ($roots.Count -eq 1 -and $roots[0].PSIsContainer) { $roots[0].FullName } else { $tmpDir }
        return @{ Root = $src; Cleanup = $tmpDir }
    } catch {
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
    }
}
