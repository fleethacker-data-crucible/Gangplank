#Requires -Version 5.1
# ============================================================
#  Gangplank.ps1 - Phase A/B host (ASCII)
# ============================================================

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
if (-not $here) { $here = (Get-Location).Path }

Import-Module (Join-Path $here "Gangplank.psm1") -Force -Global
Initialize-Gangplank -LogLevel "INFO"

Show-GangplankBanner
# Use same-process Lazarette CAC/TOTP authentication as the browser host.
$lazaretteAuth = Initialize-GangplankLazaretteAuthentication
if ($lazaretteAuth.Unlocked) {
    Write-Host '[+] Lazarette ready for GitHub and GitLab credentials.' -ForegroundColor Green
} elseif ($lazaretteAuth.Loaded) {
    Write-Host '[!] Lazarette loaded but locked. Only configured environment tokens can be used.' -ForegroundColor Yellow
} elseif ($lazaretteAuth.PSObject.Properties['Configured'] -and -not $lazaretteAuth.Configured) {
    Write-Host '[i] Lazarette not configured (optional). Using environment or saved Gangplank credentials.' -ForegroundColor DarkGray
} else {
    Write-Host '[!] Lazarette is configured but not available. Check the Lazarette folder in Integrations.' -ForegroundColor Yellow
}
$cfg = Get-GangplankConfig
$cfgItems = Get-GangplankConfigLazaretteItems -Config $cfg
Write-Host "    gitmil -> $($cfgItems.GitLab) | github -> $($cfgItems.GitHub)" -ForegroundColor DarkGray
Write-Host ""
Wait-GangplankEnter

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
    Show-GangplankBanner
    Show-Session $session

    $opts = @(
        "Open project (paste GitLab or GitHub URL)",
        "Get latest files (download branch snapshot)",
        "Smart Save (automatic message, safe changed files)",
        "Create review request (GitHub / GitLab)",
        "List remote branches",
        "Show session / open local folder",
        "Exit"
    )
    $choice = Show-GangplankMenu -Title "Gangplank" -Options $opts -AllowCancel
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
                $session = Open-GangplankRepository -Url $url.Trim()
                Show-Session $session
                if ($session.Branches.Count -eq 0) {
                    Write-Host "This repository has no branches yet. First-commit workflow is not supported in Smart Save." -ForegroundColor Yellow
                }
                Wait-GangplankEnter
            }
            1 {
                if (-not $session) {
                    Write-Host "Open a project first." -ForegroundColor Yellow
                    Wait-GangplankEnter; continue
                }
                $br = $session.DefaultBranch
                Write-Host "Branch to download [$br]:" -ForegroundColor Cyan
                $in = Read-Host
                if (-not [string]::IsNullOrWhiteSpace($in)) { $br = $in.Trim() }

                $suggest = Get-GangplankSafeWorkspacePath -Base (Join-Path $here 'work') -Project $session.ProjectPath -Branch $br
                $fp = Show-GangplankMenu -Title "Local folder" -Options @(
                    "Use suggested (created on download)",
                    "Choose folder (popup)",
                    "Cancel"
                ) -DefaultIndex 0 -AllowCancel
                if ($fp -lt 0 -or $fp -eq 2) { continue }
                $dest = $suggest
                if ($fp -eq 1) {
                    $picked = Select-GangplankFolder -Description "Gangplank download folder" -InitialDirectory $here
                    if (-not $picked) { continue }
                    $dest = $picked
                }
                Write-Host "Downloading..." -ForegroundColor Cyan
                $path = Invoke-GangplankPull -Session $session -Branch $br -LocalPath $dest
                $session.LocalPath = $path
                $session.LastBranch = $br
                Write-Host "[OK] $path" -ForegroundColor Green
                Wait-GangplankEnter
            }
            2 {
                if (-not $session -or -not $session.LocalPath) {
                    Write-Host 'Open and download a project first (option 1, then 2).' -ForegroundColor Yellow
                    Wait-GangplankEnter
                    continue
                }
                $preview = Get-GangplankWorkspacePreview -Session $session
                if ($preview.RemoteChanged) {
                    Write-Host 'Your branch changed online. Saving is blocked to protect your teammates.' -ForegroundColor Yellow
                    Write-Host 'Download a fresh workspace and reconcile local edits.' -ForegroundColor Gray
                    Wait-GangplankEnter
                    continue
                }
                $selected = @($preview.Changes | Where-Object { $_.Selected })
                if ($selected.Count -eq 0) {
                    Write-Host 'No safe changes to save.' -ForegroundColor Green
                    Wait-GangplankEnter
                    continue
                }
                Write-Host 'Gangplank Smart Save' -ForegroundColor Cyan
                Write-Host 'The following files will be saved (deletions are excluded):' -ForegroundColor Gray
                foreach ($file in $selected) { Write-Host ("  {0}: {1}" -f $file.Kind,$file.Path) }
                $added = @($selected | Where-Object { $_.Kind -eq 'New' } | ForEach-Object Path)
                $modified = @($selected | Where-Object { $_.Kind -eq 'Modified' } | ForEach-Object Path)
                $msg = New-GangplankSmartMessage -Added $added -Modified $modified
                Write-Host ("Automatic message: {0}" -f $msg.Title) -ForegroundColor Green
                $yes = Read-Host 'Type YES to publish these selected changes'
                if ($yes -cne 'YES') {
                    Write-Host 'Save cancelled.' -ForegroundColor Yellow
                    Wait-GangplankEnter
                    continue
                }
                # Plain-language public destination acknowledgement is separate from the general save prompt.
                $destination = Get-GangplankSentinelDestination -Session $session
                $publicConfirmed = $false
                if ($destination.Public) {
                    if ((Get-GangplankEnv ALLOW_PUBLIC_PUBLISH) -ne '1') {
                        throw 'Public repository publishing is disabled by Gangplank policy.'
                    }
                    Write-Host 'WARNING: This repository is PUBLIC. Anyone may read uploaded files and commit history.' -ForegroundColor Yellow
                    $publicConfirmed = ((Read-Host 'Type PUBLIC to confirm you have authorization for release') -ceq 'PUBLIC')
                    if (-not $publicConfirmed) { Write-Host 'Publication cancelled.'; continue }
                }
                $saved = Invoke-GangplankWorkspaceSave -Session $session -SelectedPaths @($selected | ForEach-Object Path) -PublicConfirmed:$publicConfirmed
                Write-Host ("Saved {0} files: {1}" -f $saved.FileCount,$saved.Message) -ForegroundColor Green
                Write-Host $saved.Url -ForegroundColor Cyan
                Wait-GangplankEnter
            }
            3 {
                if (-not $session) {
                    Write-Host "Open a GitLab project first." -ForegroundColor Yellow
                    Wait-GangplankEnter; continue
                }
                if ($session.Provider -ne "GitLab") {
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
                $mr = New-GangplankMergeRequest -Session $session -SourceBranch $src -TargetBranch $tgt -Title $title -Description $desc
                $reviewUrl = if ($mr.html_url) { $mr.html_url } else { $mr.web_url }
                Write-Host "[OK] $reviewUrl" -ForegroundColor Green
                Wait-GangplankEnter
            }
            4 {
                if (-not $session) {
                    Write-Host "Open a project first." -ForegroundColor Yellow
                } elseif ($session.Branches.Count -eq 0) {
                    Write-Host "No branches (empty repo until first push)." -ForegroundColor Yellow
                } else {
                    $session.Branches | ForEach-Object { Write-Host "  $_" }
                }
                Wait-GangplankEnter
            }
            5 {
                Show-Session $session
                if ($session -and $session.LocalPath -and (Test-Path $session.LocalPath) -and $env:OS -eq "Windows_NT") {
                    $o = Show-GangplankMenu -Title "Open in Explorer?" -Options @("Yes","No") -DefaultIndex 0
                    if ($o -eq 0) { try { Start-Process explorer.exe $session.LocalPath } catch {} }
                }
                Wait-GangplankEnter
            }
        }
    }
    catch {
        Write-GangplankError -ErrorRecord $_ -Context "Menu"
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
            Write-Host "See Logs\gangplank-*.log" -ForegroundColor Yellow
        }
        Wait-GangplankEnter
    }
}
