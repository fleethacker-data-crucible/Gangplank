#Requires -Version 5.1
# ============================================================
#  Core/Utils.ps1
# ============================================================

function Get-GangplankEnv {
    # GANGPLANK_<Name> first, then the pre-rename KEYSTONE_<Name> (Gangplank was Keystone).
    # Returns $null when neither is set (or both are blank).
    param([Parameter(Mandatory)][string]$Name)
    foreach ($n in @("GANGPLANK_$Name", "KEYSTONE_$Name")) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

function Get-GangplankTimestamp {
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Get-GangplankSafeName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "unnamed" }
    $s = $Name -replace '[\\/:*?"<>|]', '_'
    $s = $s -replace '\s+', '_'
    return $s.Trim('_')
}

function Get-GangplankHttpStatus {
    # Status code from an Invoke-RestMethod/Invoke-WebRequest error on PS 5.1 or 7, or $null.
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $null -ne $resp.StatusCode) { return [int]$resp.StatusCode }
    } catch { }
    return $null
}

function ConvertTo-GangplankRefPath {
    # Percent-encode each segment of a branch name but keep '/' separators, for
    # REST paths such as git/ref/heads/<branch>.
    param([Parameter(Mandatory)][string]$Ref)
    return (($Ref -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Get-GangplankSafeErrorMessage {
    # Reduce an exception message to something safe to return to the browser:
    # one line, bounded, and with any provider response body (" | ...") removed.
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'The request failed.' }
    $line = ($Message -split '[\r\n]')[0]
    $pipe = $line.IndexOf(' | ')
    if ($pipe -gt 0) { $line = $line.Substring(0,$pipe) }
    if ($line.Length -gt 300) { $line = $line.Substring(0,300) + '...' }
    return $line
}

function Get-GangplankFileMap {
    param([string]$RootPath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $RootPath)) { return $map }
    Get-ChildItem -LiteralPath $RootPath -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($RootPath.Length).TrimStart('\', '/').Replace('\', '/')
        if ($rel) {
            try {
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                $map[$rel] = [PSCustomObject]@{ FullName = $_.FullName; Hash = $hash; Length = $_.Length }
            } catch { }
        }
    }
    return $map
}

function Copy-GangplankTree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        $dest = Join-Path $Destination $_.Name
        if ($_.PSIsContainer) {
            Copy-GangplankTree -Source $_.FullName -Destination $dest
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }
    }
}


function Clear-GangplankInputBuffer {
    # Drain leftover keypresses so the next menu/Read-Host is not auto-selected
    try {
        while ($Host.UI.RawUI.KeyAvailable) {
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    } catch { }
    try {
        while ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
        }
    } catch { }
}

function Show-GangplankMenu {
    param(
        [string]$Title = "Select",
        [string[]]$Options,
        [int]$DefaultIndex = 0,
        [switch]$AllowCancel
    )
    if (-not $Options -or $Options.Count -eq 0) { throw "Show-GangplankMenu: Options empty" }
    Clear-GangplankInputBuffer

    $selected = [Math]::Max(0, [Math]::Min($DefaultIndex, $Options.Count - 1))
    $isWindows = ($env:OS -eq "Windows_NT")

    function Draw {
        Clear-Host
        $width = 72
        $hline = "-" * ($width - 2)
        Write-Host ("+" + $hline + "+") -ForegroundColor Cyan
        $t = " $Title "
        if ($t.Length -gt ($width - 2)) { $t = $t.Substring(0, $width - 5) + "..." }
        $pad = ($width - 2) - $t.Length
        $left = [Math]::Floor($pad / 2)
        Write-Host ("|" + (" " * $left) + $t + (" " * ($pad - $left)) + "|") -ForegroundColor Cyan
        Write-Host ("+" + $hline + "+") -ForegroundColor Cyan
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $raw = $Options[$i]
            if ($raw.Length -gt ($width - 4)) { $raw = $raw.Substring(0, $width - 7) + "..." }
            $content = " " + $raw
            $content = $content + (" " * (($width - 2) - $content.Length))
            if ($i -eq $selected) {
                Write-Host "|" -NoNewline -ForegroundColor Cyan
                Write-Host $content -NoNewline -ForegroundColor Black -BackgroundColor White
                Write-Host "|" -ForegroundColor Cyan
            } else {
                Write-Host ("|" + $content + "|") -ForegroundColor Gray
            }
        }
        Write-Host ("+" + $hline + "+") -ForegroundColor Cyan
        Write-Host "  Up/Down  Enter select" -NoNewline -ForegroundColor DarkCyan
        if ($AllowCancel) { Write-Host "  Esc cancel" -ForegroundColor DarkCyan } else { Write-Host "" }
    }

    Draw
    while ($true) {
        $action = "Other"
        if ($isWindows) {
            try {
                $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                switch ($key.VirtualKeyCode) {
                    38 { $action = "Up" }
                    40 { $action = "Down" }
                    13 { $action = "Enter" }
                    27 { $action = "Escape" }
                }
            } catch {
                $k = [Console]::ReadKey($true)
                switch ($k.Key) {
                    "UpArrow"   { $action = "Up" }
                    "DownArrow" { $action = "Down" }
                    "Enter"     { $action = "Enter" }
                    "Escape"    { $action = "Escape" }
                }
            }
        } else {
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                "UpArrow"   { $action = "Up" }
                "DownArrow" { $action = "Down" }
                "Enter"     { $action = "Enter" }
                "Escape"    { $action = "Escape" }
            }
        }
        switch ($action) {
            "Up"     { $selected = ($selected - 1 + $Options.Count) % $Options.Count; Draw }
            "Down"   { $selected = ($selected + 1) % $Options.Count; Draw }
            "Enter"  { Clear-Host; return $selected }
            "Escape" {
                if ($AllowCancel) { Clear-Host; return -1 }
            }
        }
    }
}

function Wait-GangplankEnter {
    param([string]$Prompt = "Press Enter to continue...")
    Write-Host $Prompt -ForegroundColor DarkGray
    [void](Read-Host)
}

function Select-GangplankFolder {
    param(
        [string]$Description = "Choose a folder for this repository",
        [string]$InitialDirectory = ""
    )
    # Windows: FolderBrowserDialog popup. Elsewhere: typed path.
    $isWindows = ($env:OS -eq "Windows_NT")
    if ($isWindows) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = $Description
            $dialog.ShowNewFolderButton = $true
            if (-not [string]::IsNullOrWhiteSpace($InitialDirectory) -and (Test-Path -LiteralPath $InitialDirectory)) {
                $dialog.SelectedPath = $InitialDirectory
            }
            # Make dialog topmost relative to console
            $result = $dialog.ShowDialog()
            if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $dialog.SelectedPath) {
                return $dialog.SelectedPath
            }
            return $null
        } catch {
            Write-GangplankLog -Level WARN -Message "Folder dialog unavailable: $($_.Exception.Message)"
        }
    }
    Write-Host $Description -ForegroundColor Cyan
    if ($InitialDirectory) {
        Write-Host "Default: $InitialDirectory" -ForegroundColor DarkGray
        Write-Host "Press Enter to accept default, or type a full path:" -ForegroundColor Cyan
    } else {
        Write-Host "Type a full folder path:" -ForegroundColor Cyan
    }
    $typed = Read-Host
    if ([string]::IsNullOrWhiteSpace($typed)) {
        if ($InitialDirectory) { return $InitialDirectory }
        return $null
    }
    return $typed.Trim().Trim('"')
}

function Get-GangplankSuggestedWorkPath {
    param(
        [string]$ProjectPath,
        [string]$Branch,
        [string]$ToolRoot
    )
    if (-not $ToolRoot) { $ToolRoot = (Get-Location).Path }
    $safeRepo = Get-GangplankSafeName ($ProjectPath -replace '/', '-')
    $safeBranch = Get-GangplankSafeName $Branch
    return (Join-Path $ToolRoot "work\$safeRepo\$safeBranch")
}

function Show-GangplankBanner {
    Clear-Host
    $bar = "=" * 56
    Write-Host $bar -ForegroundColor Cyan
    Write-Host "  GANGPLANK  -  GitLab / GitHub  (no git.exe)" -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host "  Open a project, get files, share updates, create MRs." -ForegroundColor Gray
    Write-Host ""
}

