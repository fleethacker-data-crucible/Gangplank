#Requires -Version 5.1
# Offline checks for using an existing folder: a git clone (branch and commit read from .git,
# loose or packed refs), a plain folder matched to a branch head, and the refusals (detached
# HEAD, unpushed commit, a folder that is not this project, bad paths). The provider serves a
# zip built here, so no network is used, and the folder itself is never changed.
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
class GangplankFakeAdoptGitHub : GitHubProvider {
    [hashtable]$Heads
    [string]$ZipPath
    [string]$MissingRef
    [System.Collections.Generic.List[string]]$Downloads
    GangplankFakeAdoptGitHub([hashtable]$heads,[string]$zipPath) : base('https://api.github.com','test-token') {
        $this.Heads = $heads
        $this.ZipPath = $zipPath
        $this.MissingRef = ''
        $this.Downloads = New-Object System.Collections.Generic.List[string]
    }
    [string] GetRefSha([string]$projectPath,[string]$branch) {
        if ($this.Heads.ContainsKey($branch)) { return [string]$this.Heads[$branch] }
        return $null
    }
    [void] DownloadArchive([string]$projectPath,[string]$ref,[string]$outZip) {
        $this.Downloads.Add($ref)
        if ($ref -eq $this.MissingRef) { throw 'NOT_FOUND|GitHub API GET zipball failed (HTTP 404).' }
        Copy-Item -LiteralPath $this.ZipPath -Destination $outZip -Force
    }
}
'@
    function Write-File([string]$Dir,[string]$Name,[string]$Text) {
        $p = Join-Path $Dir ($Name.Replace('/','\'))
        [void](New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force)
        [IO.File]::WriteAllText($p, $Text)
    }
    function Get-Code([scriptblock]$Block) {
        try { & $Block; return '' } catch { return ([string]$_.Exception.Message -split '\|')[0] }
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('gp-adopt-' + [guid]::NewGuid().ToString('N'))
    $sha = ('a' * 40); $newer = ('b' * 40); $unpushed = ('c' * 40)

    # The project online: one top-level folder in the archive, as GitHub packs it.
    $top = Join-Path (Join-Path $temp 'pack') 'team-demo-aaaa'
    Write-File $top 'a.txt' 'a v1'
    Write-File $top 'b.txt' 'b v1'
    Write-File $top 'src/c.txt' 'c v1'
    $zip = Join-Path $temp 'project.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($top, $zip, [IO.Compression.CompressionLevel]::Fastest, $true)
    $provider = [GangplankFakeAdoptGitHub]::new(@{ main = $newer; work = $sha }, $zip)
    function New-Session { [pscustomobject]@{ Provider = 'GitHub'; ProviderObj = $provider; ProjectPath = 'team/demo'; DefaultBranch = 'main'; LastBranch = $null; Branches = @('main','work'); LocalPath = $null; BaselineSha = $null; BaselineMap = @{} } }
    function Snapshot([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Dir.Length) + ':' + (Get-GangplankFileSha256 -Path $_.FullName) } | Sort-Object) -join '|' }

    # --- A git clone on branch work, with loose refs: b edited, n added, src/c.txt missing ---
    $clone = Join-Path $temp 'clone'
    Write-File $clone 'a.txt' 'a v1'
    Write-File $clone 'b.txt' 'b edited'
    Write-File $clone 'n.txt' 'new'
    Write-File $clone '.git/HEAD' "ref: refs/heads/work`n"
    Write-File $clone '.git/refs/heads/work' ($sha + "`n")
    $before = Snapshot $clone
    $session = New-Session
    $r = Add-GangplankExistingFolder -Session $session -Folder $clone
    Assert ($r.Source -eq 'git clone' -and $r.Branch -eq 'work' -and $r.Sha -eq $sha) ("Clone branch/commit not read: $($r.Source) $($r.Branch) $($r.Sha)")
    Assert ($r.Same -eq 1 -and $r.Modified -eq 1 -and $r.New -eq 1 -and $r.Missing -eq 1) ("Clone comparison wrong: same=$($r.Same) modified=$($r.Modified) new=$($r.New) missing=$($r.Missing)")
    Assert (-not $r.Behind -and -not $r.OnDefaultBranch) 'work is at the online head and is not the default branch'
    Assert ($session.LocalPath -eq $clone -and $session.BaselineSha -eq $sha -and $session.LastBranch -eq 'work') 'The session must point at the clone'
    $kinds = (@((Get-GangplankWorkspacePreview -Session $session).Changes | Sort-Object Path) | ForEach-Object { $_.Path + ':' + $_.Kind }) -join ','
    Assert ($kinds -eq 'b.txt:Modified,n.txt:New,src/c.txt:Deleted') "Pending changes of the clone: $kinds"
    Assert ((Snapshot $clone) -eq $before) 'Adopting must not change the folder'
    Assert ($provider.Downloads[0] -eq $sha) 'The baseline is the archive at the clone commit'

    # --- Packed refs, and a branch that has moved on online (Behind) ---
    Remove-Item -LiteralPath (Join-Path $clone '.git\refs') -Recurse -Force
    Write-File $clone '.git/packed-refs' ("# pack-refs with: peeled fully-peeled sorted`n" + $unpushed + " refs/heads/other`n" + $sha + " refs/heads/work`n")
    $provider.Heads['work'] = $newer
    $session = New-Session
    $r = Add-GangplankExistingFolder -Session $session -Folder $clone
    Assert ($r.Sha -eq $sha -and $r.Behind) 'Commit from packed-refs; the branch has moved on online, so Behind'
    Assert ((Get-GangplankWorkspacePreview -Session $session).RemoteChanged) 'A clone behind the branch is reported as stale (Get latest)'
    $provider.Heads['work'] = $sha

    # --- Detached HEAD and unpushed commit are refused with a way forward ---
    $detached = Join-Path $temp 'detached'
    Write-File $detached 'a.txt' 'a v1'
    Write-File $detached '.git/HEAD' ($sha + "`n")
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder $detached }) -eq 'BAD_STATE') 'A detached HEAD is refused'
    $local = Join-Path $temp 'unpushed'
    Write-File $local 'a.txt' 'a v1'
    Write-File $local '.git/HEAD' "ref: refs/heads/work`n"
    Write-File $local '.git/refs/heads/work' ($unpushed + "`n")
    $provider.MissingRef = $unpushed
    $msg = ''
    try { [void](Add-GangplankExistingFolder -Session (New-Session) -Folder $local) } catch { $msg = [string]$_.Exception.Message }
    Assert ($msg -match '^NOT_FOUND\|.*not online yet') ("An unpushed commit must be explained: $msg")
    $provider.MissingRef = ''

    # --- A plain folder, matched to a branch head ---
    $plain = Join-Path $temp 'plain'
    Write-File $plain 'a.txt' 'a v1'
    Write-File $plain 'src/c.txt' 'c edited'
    $session = New-Session
    $r = Add-GangplankExistingFolder -Session $session -Folder $plain -Branch 'work'
    Assert ($r.Source -eq 'plain folder' -and $r.Branch -eq 'work' -and $r.Sha -eq $sha) 'A plain folder is matched to the branch head'
    Assert ($r.Same -eq 1 -and $r.Modified -eq 1 -and $r.Missing -eq 1) ("Plain comparison wrong: same=$($r.Same) modified=$($r.Modified) missing=$($r.Missing)")
    $r = Add-GangplankExistingFolder -Session (New-Session) -Folder $plain
    Assert ($r.Branch -eq 'main' -and $r.OnDefaultBranch) 'Without a branch the default branch is used, and flagged'

    # --- Folders that are not this project, and bad input ---
    $stranger = Join-Path $temp 'stranger'
    Write-File $stranger 'holiday-photos.txt' 'not the project'
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder $stranger -Branch 'work' }) -eq 'BAD_REQUEST') 'A folder with no matching file is refused'
    # Publishing is the same folder with the matching rule waived: every file is new, the project's files are "missing".
    $r = Add-GangplankExistingFolder -Session (New-Session) -Folder $stranger -Branch 'work' -Unrelated
    Assert ($r.Same -eq 0 -and $r.New -eq 1 -and $r.Missing -eq 3) ("Unrelated folder: same=$($r.Same) new=$($r.New) missing=$($r.Missing)")
    $withGit = Join-Path $temp 'publish-with-git'
    Write-File $withGit 'lesson.md' 'a lesson'
    Write-File $withGit '.git/HEAD' "ref: refs/heads/somewhere-else`n"
    $r = Add-GangplankExistingFolder -Session (New-Session) -Folder $withGit -Branch 'work' -Unrelated
    Assert ($r.Source -eq 'plain folder' -and $r.Branch -eq 'work') 'With -Unrelated a .git folder is not read as the branch to use'
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder $plain -Branch 'ghost' }) -eq 'NOT_FOUND') 'A branch that is not online is refused'
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder $plain -Branch '../x' }) -eq 'BAD_REQUEST') 'A bad branch name is refused'
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder '' }) -eq 'BAD_REQUEST') 'An empty folder is refused'
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder (Join-Path $temp 'nowhere') }) -eq 'NOT_FOUND') 'A missing folder is refused'
    Assert ((Get-Code { Add-GangplankExistingFolder -Session (New-Session) -Folder ([IO.Path]::GetPathRoot($temp)) }) -eq 'BAD_REQUEST') 'A whole drive is refused'

    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Adopt existing folder checks passed.' -ForegroundColor Green
