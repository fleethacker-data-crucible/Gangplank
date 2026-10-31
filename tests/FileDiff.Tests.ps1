#Requires -Version 5.1
# Offline checks for GET /api/diff (Get-GangplankFileDiff): modified, new and deleted
# files, binary and excluded files, and path rules. The provider is a subclass of the
# real GitHub provider whose two reads are scripted, so no network is used.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$module = Get-Module Gangplank
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    Initialize-GangplankLogging -LogDir (Join-Path ([IO.Path]::GetTempPath()) 'gangplank-test-logs') -Level ERROR

    Invoke-Expression @'
class GangplankFakeDiffGitHub : GitHubProvider {
    [string]$Head
    [hashtable]$Files
    GangplankFakeDiffGitHub([string]$head,[hashtable]$files) : base('https://api.github.com','test-token') {
        $this.Head = $head
        $this.Files = $files
    }
    [string] GetRefSha([string]$projectPath,[string]$branch) { return $this.Head }
    [hashtable] GetFileText([string]$projectPath,[string]$ref,[string]$path,[int]$maxBytes) {
        if ($this.Files.ContainsKey($path)) { return @{ Found = $true; Size = 0; TooLarge = $false; Binary = $false; Text = [string]$this.Files[$path] } }
        return @{ Found = $false }
    }
}
'@

    $folder = Join-Path ([IO.Path]::GetTempPath()) ('gp-diff-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'notes.txt'), "line one changed`n")   # modified
    [IO.File]::WriteAllText((Join-Path $folder 'new.txt'), "fresh file`n")           # new
    [IO.File]::WriteAllText((Join-Path $folder '.env'), "TOKEN=fake-value`n")        # excluded by name
    [IO.File]::WriteAllBytes((Join-Path $folder 'blob.bin'), [byte[]](0,1,2,0,3))    # binary, new

    $provider = $script:GangplankFakeDiffGitHub = [GangplankFakeDiffGitHub]::new('head-1', @{
        'notes.txt' = "line one`n"
        'gone.txt'  = "was here`n"
        '.env'      = "TOKEN=from-baseline`n"
    })
    $session = [pscustomobject]@{
        Provider = 'GitHub'; ProviderObj = $provider; ProjectPath = 'team/demo'
        DefaultBranch = 'main'; LastBranch = 'work'; Branches = @('main','work')
        LocalPath = $folder; BaselineSha = 'head-1'
        BaselineMap = @{ 'notes.txt' = 'stale-hash'; 'gone.txt' = 'stale-hash'; '.env' = 'stale-hash' }
    }

    # Modified: before comes from the baseline commit, after from the local file.
    $d = Get-GangplankFileDiff -Session $session -Path 'notes.txt'
    Assert ($d.kind -eq 'Modified') ("notes.txt should be Modified, was " + $d.kind)
    Assert ($d.before -eq "line one`n") 'Before must be the baseline text'
    Assert ($d.after -eq "line one changed`n") 'After must be the local text'
    Assert (-not $d.binary -and -not $d.excluded -and -not $d.truncated) 'A plain text change has no flags set'

    # New: nothing before.
    $d = Get-GangplankFileDiff -Session $session -Path 'new.txt'
    Assert ($d.kind -eq 'New' -and $d.before -eq '' -and $d.after -eq "fresh file`n") 'A new file has only an after side'

    # Deleted: the baseline text is shown, nothing local.
    $d = Get-GangplankFileDiff -Session $session -Path 'gone.txt'
    Assert ($d.kind -eq 'Deleted' -and $d.before -eq "was here`n" -and $d.after -eq '') 'A deleted file has only a before side'

    # Excluded by name: no content from either side leaves the host.
    $d = Get-GangplankFileDiff -Session $session -Path '.env'
    Assert $d.excluded 'A secret-named file is excluded'
    Assert ($d.before -eq '' -and $d.after -eq '') 'Excluded files must not return any text'

    # Binary: flagged, no text.
    $d = Get-GangplankFileDiff -Session $session -Path 'blob.bin'
    Assert $d.binary 'A file with NUL bytes is binary'
    Assert ($d.after -eq '' -and $d.before -eq '') 'Binary files must not return text'

    # Paths: only pending changes, no traversal, no absolute paths.
    foreach ($bad in @('../secret.txt','notes.txt/../../x','C:/Windows/win.ini','/etc/passwd','a\b.txt')) {
        $threw = ''
        try { [void](Get-GangplankFileDiff -Session $session -Path $bad) } catch { $threw = [string]$_.Exception.Message }
        Assert ($threw -match '^BAD_REQUEST\|') ("Path must be refused: $bad ($threw)")
    }
    $threw = ''
    try { [void](Get-GangplankFileDiff -Session $session -Path 'unchanged.txt') } catch { $threw = [string]$_.Exception.Message }
    Assert ($threw -match '^NOT_FOUND\|') 'A file that is not a pending change is not served'

    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'File diff checks passed.' -ForegroundColor Green
