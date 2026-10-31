#Requires -Version 5.1
# Offline checks for Get latest: files changed only online are applied, overlaps ask first
# and touch nothing until every one has a choice, "theirs" saves the local copy aside, "mine"
# keeps it and records the online version as the new baseline, and bad choices are refused.
# The provider serves a zip built here, so no network is used.
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
class GangplankFakeLatestGitHub : GitHubProvider {
    [string]$Head
    [string]$ZipPath
    GangplankFakeLatestGitHub([string]$head,[string]$zipPath) : base('https://api.github.com','test-token') {
        $this.Head = $head
        $this.ZipPath = $zipPath
    }
    [string] GetRefSha([string]$projectPath,[string]$branch) { return $this.Head }
    [void] DownloadArchive([string]$projectPath,[string]$ref,[string]$outZip) { Copy-Item -LiteralPath $this.ZipPath -Destination $outZip -Force }
}
'@
    function Write-File([string]$Dir,[string]$Name,[string]$Text) {
        $p = Join-Path $Dir ($Name.Replace('/','\'))
        [void](New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force)
        [IO.File]::WriteAllText($p, $Text)
    }
    function Read-File([string]$Dir,[string]$Name) { [IO.File]::ReadAllText((Join-Path $Dir ($Name.Replace('/','\')))) }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('gp-latest-' + [guid]::NewGuid().ToString('N'))
    $baseDir = Join-Path $temp 'base'
    $headTop = Join-Path (Join-Path $temp 'pack') 'team-demo-head2'
    foreach ($f in @('a.txt','b.txt','c.txt','d.txt','e.txt')) { Write-File $baseDir $f ($f + ' v1') }

    # Online, a newer commit: a changed, b same, c changed, d changed, e deleted, f added.
    Write-File $headTop 'a.txt' 'a.txt online'
    Write-File $headTop 'b.txt' 'b.txt v1'
    Write-File $headTop 'c.txt' 'c.txt online'
    Write-File $headTop 'd.txt' 'd.txt online'
    Write-File $headTop 'f.txt' 'f.txt added online'
    $zip = Join-Path $temp 'head.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($headTop, $zip, [IO.Compression.CompressionLevel]::Fastest, $true)

    # The workspace was downloaded at head1, then edited: b changed (online did not touch it),
    # c changed (overlaps the online change), d deleted (overlaps the online change), n added.
    $workspace = Join-Path $temp 'work\demo\work'
    Copy-GangplankTree -Source $baseDir -Destination $workspace
    $baseline = Get-GangplankLocalFileMap -Root $workspace
    Write-File $workspace 'b.txt' 'b.txt mine'
    Write-File $workspace 'c.txt' 'c.txt mine'
    Remove-Item -LiteralPath (Join-Path $workspace 'd.txt')
    Write-File $workspace 'n.txt' 'new local file'

    $session = [pscustomobject]@{
        Provider = 'GitHub'; ProviderObj = [GangplankFakeLatestGitHub]::new('head2', $zip); ProjectPath = 'team/demo'
        DefaultBranch = 'main'; LastBranch = 'work'; Branches = @('main','work')
        LocalPath = $workspace; BaselineSha = 'head1'; BaselineMap = $baseline
    }

    # Overlaps ask first and change nothing.
    $r = Update-GangplankWorkspaceFromRemote -Session $session
    Assert ($r.NeedsChoice -and -not $r.UpToDate) 'Overlaps must ask for a choice'
    Assert ((@($r.Overlaps | ForEach-Object path) | Sort-Object) -join ',' -eq 'c.txt,d.txt') ('Overlaps should be c.txt and d.txt, got ' + (@($r.Overlaps | ForEach-Object path) -join ','))
    $d = @($r.Overlaps | Where-Object { $_.path -eq 'd.txt' })[0]
    Assert ($d.online -eq 'changed' -and $d.yours -eq 'deleted') 'd.txt: changed online, deleted here'
    Assert ((Read-File $workspace 'a.txt') -eq 'a.txt v1' -and $session.BaselineSha -eq 'head1') 'Nothing may change while a choice is missing'

    # One choice out of two is still not enough.
    $r = Update-GangplankWorkspaceFromRemote -Session $session -Choices @{ 'c.txt' = 'theirs' }
    Assert ($r.NeedsChoice) 'Every overlap needs a choice'
    Assert ((Read-File $workspace 'c.txt') -eq 'c.txt mine') 'A partial set of choices must change nothing'

    # Bad choices are refused before any download.
    foreach ($bad in @(@{ 'c.txt' = 'both' }, @{ '../x.txt' = 'mine' }, @{ 'C:/x.txt' = 'theirs' })) {
        $code = ''
        try { [void](Update-GangplankWorkspaceFromRemote -Session $session -Choices $bad) } catch { $code = ([string]$_.Exception.Message -split '\|')[0] }
        Assert ($code -eq 'BAD_REQUEST') ('A bad choice must be refused: ' + (($bad.Keys | ForEach-Object { "$_=$($bad[$_])" }) -join ','))
    }

    # All choices: c takes the online version (local copy saved aside), d keeps the local deletion.
    $r = Update-GangplankWorkspaceFromRemote -Session $session -Choices @{ 'c.txt' = 'theirs'; 'd.txt' = 'mine' }
    Assert (-not $r.NeedsChoice -and -not $r.UpToDate) 'With all choices the update is applied'
    Assert ((Read-File $workspace 'a.txt') -eq 'a.txt online') 'A file changed only online is applied'
    Assert (-not (Test-Path -LiteralPath (Join-Path $workspace 'e.txt'))) 'A file deleted online and untouched here is removed'
    Assert ((Read-File $workspace 'f.txt') -eq 'f.txt added online') 'A file added online arrives'
    Assert ((Read-File $workspace 'c.txt') -eq 'c.txt online') '"theirs" takes the online version'
    $backup = Get-ChildItem -LiteralPath ($workspace + '.gangplank-backup') -Recurse -File | Where-Object { $_.Name -eq 'c.txt' } | Select-Object -First 1
    Assert ($backup -and [IO.File]::ReadAllText($backup.FullName) -eq 'c.txt mine') '"theirs" must save my copy aside first'
    Assert (-not (Test-Path -LiteralPath (Join-Path $workspace 'd.txt'))) '"mine" keeps my deletion'
    Assert ((Read-File $workspace 'b.txt') -eq 'b.txt mine') 'A file only I changed is untouched'
    Assert ($session.BaselineSha -eq 'head2') 'The baseline moves to the new commit'

    # What is left to save is what is really mine: b (edited), d (deleted), n (new).
    $left = @((Get-GangplankWorkspacePreview -Session $session).Changes | Sort-Object Path)
    Assert ((($left | ForEach-Object { $_.Path + ':' + $_.Kind }) -join ',') -eq 'b.txt:Modified,d.txt:Deleted,n.txt:New') ('Pending changes after update: ' + (($left | ForEach-Object { $_.Path + ':' + $_.Kind }) -join ','))
    Assert (-not (Get-GangplankWorkspacePreview -Session $session).RemoteChanged) 'The workspace is no longer behind'

    # Nothing newer: up to date, and nothing is downloaded.
    $r = Update-GangplankWorkspaceFromRemote -Session $session
    Assert $r.UpToDate 'Same commit: already up to date'

    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($workspace + '.gangplank-backup') -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Get latest checks passed.' -ForegroundColor Green
