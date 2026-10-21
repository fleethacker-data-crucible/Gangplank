#Requires -Version 5.1
# ============================================================
#  Keystone.ps1 - Phase A/B host (ASCII)
# ============================================================

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
if (-not $here) { $here = (Get-Location).Path }

Import-Module (Join-Path $here "Keystone.psm1") -Force -Global
Initialize-Keystone -LogLevel "INFO"

Show-KeystoneBanner
$arcOk = Import-KeystoneArcSession
if ($arcOk) {
    Write-Host "[+] ARC loaded" -ForegroundColor Green
    $r = Find-KeystoneArcRoot
    if ($r) { Write-Host "    $r" -ForegroundColor DarkGray }
} else {
    Write-Host "[!] ARC not found - env tokens only" -ForegroundColor Yellow
}
$cfg = Get-KeystoneConfig
Write-Host "    gitmil -> $($cfg.ArcItems.GitLab) | github -> $($cfg.ArcItems.GitHub)" -ForegroundColor DarkGray
Write-Host ""
Wait-KeystoneEnter

$session = $null

function Show-Session {
    param($S)
    if (-not $S) { return }
    Write-Host ""
    Write-Host "---------- Session ----------" -ForegroundColor Cyan
    Write-Host "  Host    : $($S.Provider)" -ForegroundColor Green
    Write-Host "  Project : $($S.ProjectPath)" -ForegroundColor Green
    Write-Host "  Default : $($S.DefaultBranch)" -ForegroundColor Green
    Write-Host "  Branches: $($S.Branches.Count)" -ForegroundColor Green
    if ($S.LocalPath) {
        Write-Host "  Local   : $($S.LocalPath)" -ForegroundColor Yellow
    } else {
        Write-Host "  Local   : (none yet)" -ForegroundColor DarkGray
    }
    Write-Host "-----------------------------" -ForegroundColor Cyan
}

while ($true) {
    Show-KeystoneBanner
    Show-Session $session

    $opts = @(
        "Open project (paste GitLab or GitHub URL)",
        "Get latest files (download branch snapshot)",
        "Share my folder (push commit - works on empty repos)",
        "Create merge request (GitLab)",
        "List remote branches",
        "Show session / open local folder",
        "Exit"
    )
    $choice = Show-KeystoneMenu -Title "Keystone" -Options $opts -AllowCancel
    if ($choice -lt 0 -or $choice -eq 6) {
        Write-Host "Goodbye." -ForegroundColor Cyan
        break
    }

    try {
        switch ($choice) {
            0 {
                Write-Host "Paste full browser URL (blank = cancel):" -ForegroundColor Cyan
                $url = Read-Host
                if ([string]::IsNullOrWhiteSpace($url)) { continue }
                Write-Host "Connecting..." -ForegroundColor DarkGray
                $session = Open-KeystoneRepository -Url $url.Trim()
                Show-Session $session
                if ($session.Branches.Count -eq 0) {
                    Write-Host "No branches yet - empty repo is OK. Use Share my folder for first commit." -ForegroundColor Yellow
                }
                Wait-KeystoneEnter
            }
            1 {
                if (-not $session) {
                    Write-Host "Open a project first." -ForegroundColor Yellow
                    Wait-KeystoneEnter; continue
                }
                $br = $session.DefaultBranch
                Write-Host "Branch to download [$br]:" -ForegroundColor Cyan
                $in = Read-Host
                if (-not [string]::IsNullOrWhiteSpace($in)) { $br = $in.Trim() }

                $suggest = Get-KeystoneSuggestedWorkPath -ProjectPath $session.ProjectPath -Branch $br -ToolRoot $here
                $fp = Show-KeystoneMenu -Title "Local folder" -Options @(
                    "Use suggested (created on download)",
                    "Choose folder (popup)",
                    "Cancel"
                ) -DefaultIndex 0 -AllowCancel
                if ($fp -lt 0 -or $fp -eq 2) { continue }
                $dest = $suggest
                if ($fp -eq 1) {
                    $picked = Select-KeystoneFolder -Description "Keystone download folder" -InitialDirectory $here
                    if (-not $picked) { continue }
                    $dest = $picked
                }
                Write-Host "Downloading..." -ForegroundColor Cyan
                $path = Invoke-KeystonePull -Session $session -Branch $br -LocalPath $dest
                $session.LocalPath = $path
                $session.LastBranch = $br
                Write-Host "[OK] $path" -ForegroundColor Green
                Wait-KeystoneEnter
            }
            2 {
                Write-KeystoneLog -Level INFO -Message "MENU: Share/push selected"
                if (-not $session) {
                    Write-Host ""
                    Write-Host "No project open. Open a project first (option 1), then come back here." -ForegroundColor Yellow
                    Write-KeystoneLog -Level WARN -Message "Push aborted: no session"
                    Wait-KeystoneEnter
                    continue
                }

                Write-Host ""
                Write-Host "======== SHARE / PUSH ========" -ForegroundColor Cyan
                Write-Host "Provider : $($session.Provider)" -ForegroundColor Gray
                Write-Host "Project  : $($session.ProjectPath)" -ForegroundColor Gray
                Write-Host "Default  : $($session.DefaultBranch)" -ForegroundColor Gray
                Write-Host "=============================" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Folder to upload:" -ForegroundColor Cyan
                Write-Host "  [Enter] = this Keystone folder:" -ForegroundColor DarkGray
                Write-Host "           $here" -ForegroundColor DarkGray
                if ($session.LocalPath) {
                    Write-Host "  Or type: session" -ForegroundColor DarkGray
                    Write-Host "           $($session.LocalPath)" -ForegroundColor DarkGray
                }
                Write-Host "  Or type a full folder path" -ForegroundColor DarkGray
                Clear-KeystoneInputBuffer
                $pathIn = Read-Host "Path"
                if ([string]::IsNullOrWhiteSpace($pathIn)) {
                    $pushPath = $here
                }
                elseif ($pathIn.Trim().ToLowerInvariant() -eq "session") {
                    if (-not $session.LocalPath) {
                        Write-Host "No session local path. Use Enter for Keystone folder." -ForegroundColor Yellow
                        Wait-KeystoneEnter; continue
                    }
                    $pushPath = $session.LocalPath
                }
                else {
                    $pushPath = $pathIn.Trim().Trim('"')
                }

                if (-not (Test-Path -LiteralPath $pushPath)) {
                    Write-Host "Folder not found: $pushPath" -ForegroundColor Red
                    Write-KeystoneLog -Level ERROR -Message "Push path missing: $pushPath"
                    Wait-KeystoneEnter; continue
                }
                Write-Host "Using folder: $pushPath" -ForegroundColor Green
                Write-KeystoneLog -Level INFO -Message "Push path=$pushPath"

                $br = if ($session.DefaultBranch) { $session.DefaultBranch } else { "main" }
                Clear-KeystoneInputBuffer
                $brIn = Read-Host "Branch [$br]"
                if (-not [string]::IsNullOrWhiteSpace($brIn)) { $br = $brIn.Trim() }

                $msg = "Commit from Keystone - $($session.ProjectPath)"
                Clear-KeystoneInputBuffer
                $msgIn = Read-Host "Commit message [default]"
                if (-not [string]::IsNullOrWhiteSpace($msgIn)) { $msg = $msgIn.Trim() }

                $policy = "Omit"
                Write-Host ""
                Write-Host "Will push:" -ForegroundColor Yellow
                Write-Host "  $pushPath" -ForegroundColor Gray
                Write-Host "  -> $($session.Provider) $($session.ProjectPath) @ $br" -ForegroundColor Gray
                Write-Host "  msg: $msg" -ForegroundColor Gray
                Clear-KeystoneInputBuffer
                $yes = Read-Host "Type YES to upload (anything else cancels)"
                if ($yes -ne "YES" -and $yes -ne "yes") {
                    Write-Host "Cancelled (you must type YES in capitals or lowercase)." -ForegroundColor Yellow
                    Write-KeystoneLog -Level INFO -Message "Push cancelled at YES prompt (got: $yes)"
                    Wait-KeystoneEnter
                    continue
                }

                Write-Host ""
                Write-Host "Uploading..." -ForegroundColor Cyan
                Write-KeystoneLog -Level INFO -Message "UI confirm push path=$pushPath branch=$br provider=$($session.Provider)"
                try {
                    $result = Invoke-KeystonePush -Session $session -LocalPath $pushPath -Branch $br -Message $msg -DeletePolicy $policy
                    Write-Host ""
                    Write-Host "[OK] Push finished" -ForegroundColor Green
                    if ($null -ne $result) {
                        Write-Host "  Files/actions : $($result.FileCount)" -ForegroundColor Green
                        if ($result.CommitSha) { Write-Host "  Commit        : $($result.CommitSha)" -ForegroundColor Green }
                        if ($result.Commits) { Write-Host "  Commits       : $($result.Commits -join ', ')" -ForegroundColor Green }
                        if ($result.Message) { Write-Host "  Note          : $($result.Message)" -ForegroundColor Cyan }
                        if ($result.Url) { Write-Host "  URL           : $($result.Url)" -ForegroundColor Yellow }
                    }
                    Write-KeystoneLog -Level INFO -Message "Push OK files=$($result.FileCount) sha=$($result.CommitSha)"
                }
                catch {
                    Write-KeystoneError -ErrorRecord $_ -Context "Push"
                    Write-Host ""
                    Write-Host "PUSH FAILED" -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    Write-Host "See Logs\keystone-*.log" -ForegroundColor Yellow
                }
                Write-Host ""
                Wait-KeystoneEnter -Prompt "Press Enter for main menu..."
            }
            3 {
                if (-not $session) {
                    Write-Host "Open a GitLab project first." -ForegroundColor Yellow
                    Wait-KeystoneEnter; continue
                }
                if ($session.Provider -ne "GitLab") {
                    Write-Host "MR is GitLab-only (GitHub PR in Phase C)." -ForegroundColor Yellow
                    Wait-KeystoneEnter; continue
                }
                $src = if ($session.LastBranch) { $session.LastBranch } else { $session.DefaultBranch }
                $tgt = $session.DefaultBranch
                Write-Host "Source branch [$src]:" -ForegroundColor Cyan
                $in = Read-Host; if (-not [string]::IsNullOrWhiteSpace($in)) { $src = $in.Trim() }
                Write-Host "Target branch [$tgt]:" -ForegroundColor Cyan
                $in = Read-Host; if (-not [string]::IsNullOrWhiteSpace($in)) { $tgt = $in.Trim() }
                Write-Host "MR title:" -ForegroundColor Cyan
                $title = Read-Host
                if ([string]::IsNullOrWhiteSpace($title)) { continue }
                Write-Host "Description (optional):" -ForegroundColor Cyan
                $desc = Read-Host
                $mr = New-KeystoneMergeRequest -Session $session -SourceBranch $src -TargetBranch $tgt -Title $title -Description $desc
                Write-Host "[OK] $($mr.web_url)" -ForegroundColor Green
                Wait-KeystoneEnter
            }
            4 {
                if (-not $session) {
                    Write-Host "Open a project first." -ForegroundColor Yellow
                } elseif ($session.Branches.Count -eq 0) {
                    Write-Host "No branches (empty repo until first push)." -ForegroundColor Yellow
                } else {
                    $session.Branches | ForEach-Object { Write-Host "  $_" }
                }
                Wait-KeystoneEnter
            }
            5 {
                Show-Session $session
                if ($session -and $session.LocalPath -and (Test-Path $session.LocalPath) -and $env:OS -eq "Windows_NT") {
                    $o = Show-KeystoneMenu -Title "Open in Explorer?" -Options @("Yes","No") -DefaultIndex 0
                    if ($o -eq 0) { try { Start-Process explorer.exe $session.LocalPath } catch {} }
                }
                Wait-KeystoneEnter
            }
        }
    }
    catch {
        Write-KeystoneError -ErrorRecord $_ -Context "Menu"
        $em = $_.Exception.Message
        if ($em -match '^EMPTY_REPO\|') {
            $em = $em -replace '^EMPTY_REPO\|', ''
            Write-Host ""
            Write-Host "Nothing to download yet." -ForegroundColor Yellow
            Write-Host $em -ForegroundColor Gray
            Write-Host "Use: Share my folder (push) to create the first commit." -ForegroundColor Cyan
        }
        else {
            Write-Host "ERROR: $em" -ForegroundColor Red
            Write-Host "See Logs\keystone-*.log" -ForegroundColor Yellow
        }
        Wait-KeystoneEnter
    }
}
