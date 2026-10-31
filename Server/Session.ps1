#Requires -Version 5.1
# =============================================================================
# Workspace session: plain snapshots (for jobs) and persistence (for restarts).
# A snapshot holds no token and no provider object. The saved state lets a
# restarted Gangplank keep its project, work branch and download baseline, so
# closing the window no longer strands unsaved work.
# =============================================================================

$script:GangplankDevGitHubUrl = $null
$script:GangplankDevGitLabUrl = $null
$script:GangplankSessionFields = @('Provider','BaseUrl','ProjectPath','DefaultBranch','Branches','LocalPath','LastBranch','BaselineSha','BaselineMap','LastSaveMessage','LastSavedFiles','LastReviewUrl')

function Set-GangplankDevProvider {
    # LocalDev only (Start-Gangplank.ps1 -LocalDev -DevGitHubUrl / -DevGitLabUrl): treat a
    # local synthetic GitHub or GitLab server as that provider's API. Loopback http only.
    [CmdletBinding()]
    param([string]$GitHubUrl,[string]$GitLabUrl)
    if (-not $GitHubUrl -and -not $GitLabUrl) { throw 'Give a synthetic GitHub or GitLab address.' }
    $parsed = @{}
    foreach ($pair in @(@('GitHub',$GitHubUrl),@('GitLab',$GitLabUrl))) {
        if (-not $pair[1]) { continue }
        $u = $null
        if (-not [uri]::TryCreate($pair[1],[UriKind]::Absolute,[ref]$u) -or $u.Scheme -ne 'http' -or $u.Host -notin @('127.0.0.1','localhost') -or $u.AbsolutePath -ne '/') {
            throw 'The synthetic provider must be http://127.0.0.1:<port>/'
        }
        $parsed[$pair[0]] = $u.GetLeftPart([UriPartial]::Authority)
    }
    if ($parsed.ContainsKey('GitHub')) { $script:GangplankDevGitHubUrl = $parsed['GitHub'] }
    if ($parsed.ContainsKey('GitLab')) { $script:GangplankDevGitLabUrl = $parsed['GitLab'] }
}

function Get-GangplankDevProvider { return $script:GangplankDevGitHubUrl }

function Get-GangplankDevGitLabProvider { return $script:GangplankDevGitLabUrl }

function Resolve-GangplankDevRepository {
    # Which synthetic provider (if any) serves this URL: @{ Provider; BaseUrl } or $null.
    param([string]$Url)
    if (-not $Url) { return $null }
    foreach ($pair in @(@('GitHub',$script:GangplankDevGitHubUrl),@('GitLab',$script:GangplankDevGitLabUrl))) {
        if ($pair[1] -and $Url.StartsWith($pair[1] + '/',[StringComparison]::OrdinalIgnoreCase)) { return @{ Provider = $pair[0]; BaseUrl = $pair[1] } }
    }
    return $null
}

function Test-GangplankDevRepositoryUrl {
    param([string]$Url)
    return [bool](Resolve-GangplankDevRepository -Url $Url)
}

function ConvertTo-GangplankSessionSnapshot {
    param($Session)
    if (-not $Session) { return $null }
    $snap = [ordered]@{}
    foreach ($f in $script:GangplankSessionFields) {
        $p = $Session.PSObject.Properties[$f]
        $snap[$f] = $(if ($p) { $p.Value } else { $null })
    }
    # A copy, never the live table: jobs run on other threads.
    $snap.BaselineMap = (ConvertTo-GangplankHashtable $snap.BaselineMap).Clone()
    $snap.Branches = @($snap.Branches)
    $snap.LastSavedFiles = @($snap.LastSavedFiles)
    return $snap
}

function ConvertTo-GangplankHashtable {
    param($Value)
    $h = @{}
    if ($null -eq $Value) { return $h }
    if ($Value -is [hashtable]) { return $Value }
    foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
    return $h
}

function New-GangplankSessionFromSnapshot {
    # Live session (with provider object) from a snapshot and a token. No network.
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$Token)
    $s = [ordered]@{}
    foreach ($f in $script:GangplankSessionFields) { $s[$f] = $Snapshot[$f] }
    if (-not $s.Provider -or -not $s.ProjectPath) { throw 'BAD_STATE|The saved session is incomplete.' }
    $s.BaselineMap = ConvertTo-GangplankHashtable $s.BaselineMap
    $s.Branches = @($s.Branches)
    $s.LastSavedFiles = @($s.LastSavedFiles)
    $base = if ($s.Provider -eq 'GitHub' -and $s.BaseUrl -match 'github\.com') { 'https://api.github.com' } else { [string]$s.BaseUrl }
    $s.ProviderObj = New-GangplankProvider -Provider $s.Provider -BaseUrl $base -Token $Token
    $s.Project = $null
    return [pscustomobject]$s
}

function Get-GangplankSessionStatePath {
    # StateRoot is Gangplank's own data folder (%LOCALAPPDATA%\Gangplank), never the workspaces.
    param([Parameter(Mandatory)][string]$StateRoot)
    return (Join-Path $StateRoot 'session.json')
}

function Save-GangplankSessionState {
    param([Parameter(Mandatory)][string]$StateRoot,$Session)
    $path = Get-GangplankSessionStatePath -StateRoot $StateRoot
    if (-not $Session) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return
    }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $doc = [ordered]@{ Version = 1; Saved = (Get-Date).ToUniversalTime().ToString('o'); Session = (ConvertTo-GangplankSessionSnapshot $Session) }
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Read-GangplankSessionState {
    # Snapshot hashtable from a previous run, or $null. Unreadable state is set aside, not deleted.
    param([Parameter(Mandatory)][string]$StateRoot)
    $path = Get-GangplankSessionStatePath -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $snap = [ordered]@{}
        foreach ($f in $script:GangplankSessionFields) {
            $p = $doc.Session.PSObject.Properties[$f]
            $snap[$f] = $(if ($p) { $p.Value } else { $null })
        }
        $snap.BaselineMap = ConvertTo-GangplankHashtable $snap.BaselineMap
        if (-not $snap.Provider -or -not $snap.ProjectPath -or -not $snap.BaseUrl) { return $null }
        # Re-check the saved address exactly as a typed URL would be checked, so a
        # session saved in LocalDev (http://127.0.0.1:...) can never send a real
        # token anywhere in a normal run.
        try { Assert-GangplankTrustedRepositoryUrl -Url (([string]$snap.BaseUrl).TrimEnd('/') + '/' + [string]$snap.ProjectPath) }
        catch {
            Write-GangplankLog -Level WARN -Message 'Saved session points at a host that is not allowed now; it was not restored.'
            return $null
        }
        if ($snap.LocalPath -and -not (Test-Path -LiteralPath $snap.LocalPath -PathType Container)) {
            $snap.LocalPath = $null; $snap.BaselineSha = $null; $snap.BaselineMap = @{}
        }
        return $snap
    } catch {
        try { Move-Item -LiteralPath $path -Destination ($path + '.unreadable-' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force } catch { }
        Write-GangplankLog -Level WARN -Message 'Saved session could not be read and was set aside.'
        return $null
    }
}
