#Requires -Version 5.1
# =============================================================================
# Workspace session: plain snapshots (for jobs) and persistence (for restarts).
# A snapshot holds no token and no provider object. The saved state lets a
# restarted Keystone keep its project, work branch and download baseline, so
# closing the window no longer strands unsaved work.
# =============================================================================

$script:KeystoneDevGitHubUrl = $null
$script:KeystoneSessionFields = @('Provider','BaseUrl','ProjectPath','DefaultBranch','Branches','LocalPath','LastBranch','BaselineSha','BaselineMap','LastSaveMessage','LastSavedFiles','LastReviewUrl')

function Set-KeystoneDevProvider {
    # LocalDev only (Start-KeystoneWeb.ps1 -LocalDev -DevGitHubUrl): treat a local
    # synthetic GitHub server as the GitHub API. Loopback http only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GitHubUrl)
    $u = $null
    if (-not [uri]::TryCreate($GitHubUrl,[UriKind]::Absolute,[ref]$u) -or $u.Scheme -ne 'http' -or $u.Host -notin @('127.0.0.1','localhost') -or $u.AbsolutePath -ne '/') {
        throw 'The synthetic provider must be http://127.0.0.1:<port>/'
    }
    $script:KeystoneDevGitHubUrl = $u.GetLeftPart([UriPartial]::Authority)
}

function Get-KeystoneDevProvider { return $script:KeystoneDevGitHubUrl }

function Test-KeystoneDevRepositoryUrl {
    param([string]$Url)
    if (-not $script:KeystoneDevGitHubUrl) { return $false }
    return $Url.StartsWith($script:KeystoneDevGitHubUrl + '/',[StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-KeystoneSessionSnapshot {
    param($Session)
    if (-not $Session) { return $null }
    $snap = [ordered]@{}
    foreach ($f in $script:KeystoneSessionFields) {
        $p = $Session.PSObject.Properties[$f]
        $snap[$f] = $(if ($p) { $p.Value } else { $null })
    }
    if ($snap.BaselineMap -isnot [hashtable]) { $snap.BaselineMap = ConvertTo-KeystoneHashtable $snap.BaselineMap }
    $snap.Branches = @($snap.Branches)
    $snap.LastSavedFiles = @($snap.LastSavedFiles)
    return $snap
}

function ConvertTo-KeystoneHashtable {
    param($Value)
    $h = @{}
    if ($null -eq $Value) { return $h }
    if ($Value -is [hashtable]) { return $Value }
    foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
    return $h
}

function New-KeystoneSessionFromSnapshot {
    # Live session (with provider object) from a snapshot and a token. No network.
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$Token)
    $s = [ordered]@{}
    foreach ($f in $script:KeystoneSessionFields) { $s[$f] = $Snapshot[$f] }
    if (-not $s.Provider -or -not $s.ProjectPath) { throw 'BAD_STATE|The saved session is incomplete.' }
    $s.BaselineMap = ConvertTo-KeystoneHashtable $s.BaselineMap
    $s.Branches = @($s.Branches)
    $s.LastSavedFiles = @($s.LastSavedFiles)
    $base = if ($s.Provider -eq 'GitHub' -and $s.BaseUrl -match 'github\.com') { 'https://api.github.com' } else { [string]$s.BaseUrl }
    $s.ProviderObj = New-KeystoneProvider -Provider $s.Provider -BaseUrl $base -Token $Token
    $s.Project = $null
    return [pscustomobject]$s
}

function Get-KeystoneSessionStatePath {
    param([Parameter(Mandatory)][string]$WorkRoot)
    return (Join-Path (Join-Path $WorkRoot '.keystone') 'session.json')
}

function Save-KeystoneSessionState {
    param([Parameter(Mandatory)][string]$WorkRoot,$Session)
    $path = Get-KeystoneSessionStatePath -WorkRoot $WorkRoot
    if (-not $Session) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return
    }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $doc = [ordered]@{ Version = 1; Saved = (Get-Date).ToUniversalTime().ToString('o'); Session = (ConvertTo-KeystoneSessionSnapshot $Session) }
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Read-KeystoneSessionState {
    # Snapshot hashtable from a previous run, or $null. Unreadable state is set aside, not deleted.
    param([Parameter(Mandatory)][string]$WorkRoot)
    $path = Get-KeystoneSessionStatePath -WorkRoot $WorkRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $snap = [ordered]@{}
        foreach ($f in $script:KeystoneSessionFields) {
            $p = $doc.Session.PSObject.Properties[$f]
            $snap[$f] = $(if ($p) { $p.Value } else { $null })
        }
        $snap.BaselineMap = ConvertTo-KeystoneHashtable $snap.BaselineMap
        if (-not $snap.Provider -or -not $snap.ProjectPath) { return $null }
        if ($snap.LocalPath -and -not (Test-Path -LiteralPath $snap.LocalPath -PathType Container)) {
            $snap.LocalPath = $null; $snap.BaselineSha = $null; $snap.BaselineMap = @{}
        }
        return $snap
    } catch {
        try { Move-Item -LiteralPath $path -Destination ($path + '.unreadable-' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force } catch { }
        Write-KeystoneLog -Level WARN -Message 'Saved session could not be read and was set aside.'
        return $null
    }
}
