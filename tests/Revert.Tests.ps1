#Requires -Version 5.1
# Offline checks for reverting one file to the downloaded version: a modified and a deleted
# file come back, a new file is refused, the edited copy is saved aside, a tampered archive
# is refused, and bad paths never reach the file system. The provider is a subclass of the
# real GitHub provider that serves a zip built here, so no network is used.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$module = Get-Module Gangplank
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    Initialize-GangplankLogging -LogDir (Join-Path ([IO.Path]::GetTempPath()) 'gangplank-test-logs') -Level ERROR
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    Invoke-Expression @'
class GangplankFakeArchiveGitHub : GitHubProvider {
    [string]$Head
    [string]$ZipPath
    GangplankFakeArchiveGitHub([string]$head,[string]$zipPath) : base('https://api.github.com','test-token') {
        $this.Head = $head
        $this.ZipPath = $zipPath
    }
    [string] GetRefSha([string]$projectPath,[string]$branch) { return $this.Head }
    [void] DownloadArchive([string]$projectPath,[string]$ref,[string]$outZip) { Copy-Item -LiteralPath $this.ZipPath -Destination $outZip -Force }
}
'@

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('gp-revert-' + [guid]::NewGuid().ToString('N'))
    # The project at the baseline commit, packed the way GitHub does: one top-level folder.
    $pack = Join-Path $temp 'pack'
    $top = Join-Path $pack 'team-demo-abc123'
    [void](New-Item -ItemType Directory -Path (Join-Path $top 'src') -Force)
    [IO.File]::WriteAllText((Join-Path $top 'notes.txt'), "version one`n")
    [IO.File]::WriteAllText((Join-Path $top 'other.txt'), "other file`n")
    [IO.File]::WriteAllText((Join-Path $top 'src\deep.txt'), "deep file`n")
    $zip = Join-Path $temp 'baseline.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($top, $zip, [IO.Compression.CompressionLevel]::Fastest, $true)

    $workspace = Join-Path $temp 'work\demo\main'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    Copy-GangplankTree -Source $top -Destination $workspace
    $baseline = Get-GangplankLocalFileMap -Root $workspace

    # Local edits: change a file, delete a file, change a nested file, add a file.
    [IO.File]::WriteAllText((Join-Path $workspace 'notes.txt'), "my edit`n")
    Remove-Item -LiteralPath (Join-Path $workspace 'other.txt')
    [IO.File]::WriteAllText((Join-Path $workspace 'src\deep.txt'), "my deep edit`n")
    [IO.File]::WriteAllText((Join-Path $workspace 'brand-new.txt'), "new`n")

    $provider = [GangplankFakeArchiveGitHub]::new('abc123', $zip)
    $session = [pscustomobject]@{
        Provider = 'GitHub'; ProviderObj = $provider; ProjectPath = 'team/demo'
        DefaultBranch = 'main'; LastBranch = 'work'; Branches = @('main','work')
        LocalPath = $workspace; BaselineSha = 'abc123'; BaselineMap = $baseline
    }
    Assert (@((Get-GangplankWorkspacePreview -Session $session).Changes).Count -eq 4) 'Four pending changes to start with'

    # Modified: the downloaded text comes back and the edited copy is saved aside.
    $r = Restore-GangplankWorkspaceFile -Session $session -Path 'notes.txt'
    Assert ([IO.File]::ReadAllText((Join-Path $workspace 'notes.txt')) -eq "version one`n") 'The modified file must be restored'
    Assert ($r.Kind -eq 'Modified' -and $r.BackupPath -and (Test-Path -LiteralPath $r.BackupPath)) 'The edited copy must be saved aside'
    Assert ([IO.File]::ReadAllText($r.BackupPath) -eq "my edit`n") 'The backup holds the edited text'
    Assert (-not $r.BackupPath.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar)) 'The backup must be outside the workspace'

    # Deleted: the file returns, with no backup because there was nothing to keep.
    $r = Restore-GangplankWorkspaceFile -Session $session -Path 'other.txt'
    Assert ([IO.File]::ReadAllText((Join-Path $workspace 'other.txt')) -eq "other file`n") 'The deleted file must come back'
    Assert ($r.Kind -eq 'Deleted' -and -not $r.BackupPath) 'A deleted file has nothing to back up'

    # Nested path.
    [void](Restore-GangplankWorkspaceFile -Session $session -Path 'src/deep.txt')
    Assert ([IO.File]::ReadAllText((Join-Path $workspace 'src\deep.txt')) -eq "deep file`n") 'A file in a folder is restored too'

    # Only the new file is left as a change, and it cannot be reverted.
    $left = @((Get-GangplankWorkspacePreview -Session $session).Changes)
    Assert ($left.Count -eq 1 -and $left[0].Path -eq 'brand-new.txt') 'Only the new file should remain a change'
    $code = ''
    try { [void](Restore-GangplankWorkspaceFile -Session $session -Path 'brand-new.txt') } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'BAD_STATE') "A new file has no earlier version, got $code"
    Assert (Test-Path -LiteralPath (Join-Path $workspace 'brand-new.txt')) 'A refused revert must leave the new file alone'

    # Not a pending change, and paths that must never reach the file system.
    $code = ''
    try { [void](Restore-GangplankWorkspaceFile -Session $session -Path 'notes.txt') } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'NOT_FOUND') "A file with no changes is not a pending change, got $code"
    foreach ($bad in @('../outside.txt','a/../../b.txt','C:/Windows/win.ini','/etc/passwd','a\b.txt','')) {
        $code = ''
        try { [void](Restore-GangplankWorkspaceFile -Session $session -Path $bad) } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
        Assert ($code -eq 'BAD_REQUEST') ("Path must be refused: '$bad' ($code)")
    }

    # A tampered archive (its file no longer matches the baseline hash) is refused and changes nothing.
    [IO.File]::WriteAllText((Join-Path $workspace 'notes.txt'), "second edit`n")
    [IO.File]::WriteAllText((Join-Path $top 'notes.txt'), "TAMPERED`n")
    $badZip = Join-Path $temp 'tampered.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($top, $badZip, [IO.Compression.CompressionLevel]::Fastest, $true)
    $session.ProviderObj = [GangplankFakeArchiveGitHub]::new('abc123', $badZip)
    $code = ''
    try { [void](Restore-GangplankWorkspaceFile -Session $session -Path 'notes.txt') } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
    Assert ($code -eq 'BAD_STATE') "A tampered archive must be refused, got $code"
    Assert ([IO.File]::ReadAllText((Join-Path $workspace 'notes.txt')) -eq "second edit`n") 'A refused revert must keep the local edit'

    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Revert checks passed.' -ForegroundColor Green
