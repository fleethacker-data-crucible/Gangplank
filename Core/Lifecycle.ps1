#Requires -Version 5.1
# ============================================================
#  Core/Lifecycle.ps1 - browser presence, runtime files, and
#  finding / stopping running Gangplank web hosts.
#
#  Loaded by Gangplank.psm1 (the web host calls it from the HTTP
#  loop), and dot-sourced on its own by Start-Gangplank.ps1
#  (single-instance check before the module and Lazarette load),
#  Stop-Gangplank.ps1 and tests. Needs nothing else from Gangplank.
# ============================================================

$script:GangplankPresence = $null

# ---------- presence: the browser tab owns the server ----------
# The UI sends POST /api/heartbeat every 5 s, and a "leaving" beacon on pagehide.
# Each tab sends its own random id, so with two tabs open, closing one does not stop
# the host. A tab is gone 20 s after its last heartbeat, or 5 s after its leaving
# signal (a reload sends a new heartbeat from a new tab id well inside that).
# The host stops when every tab it has seen is gone. Until the first heartbeat
# nothing stops (-NoBrowser, diagnostics, CI).

function Reset-GangplankPresence {
    param(
        [bool]$AutoStop = $true,
        [int]$TimeoutSeconds = 20,
        [int]$LeavingGraceSeconds = 5
    )
    $script:GangplankPresence = @{
        AutoStop  = $AutoStop
        Timeout   = [TimeSpan]::FromSeconds($TimeoutSeconds)
        Grace     = [TimeSpan]::FromSeconds($LeavingGraceSeconds)
        Tabs      = @{}
        EverSeen  = $false
        BusyUntil = $null
    }
}

function Get-GangplankTabDeadline {
    param([Parameter(Mandatory)][hashtable]$Tab)
    $p = $script:GangplankPresence
    if ($null -ne $Tab.LeavingAt) { return ([DateTime]$Tab.LeavingAt) + $p.Grace }
    return ([DateTime]$Tab.Seen) + $p.Timeout
}

function Register-GangplankPresence {
    <# Records a heartbeat (or, with -Leaving, the tab's unload signal). #>
    param(
        [string]$TabId,
        [switch]$Leaving,
        [DateTime]$Now = [DateTime]::UtcNow
    )
    if ($null -eq $script:GangplankPresence) { Reset-GangplankPresence }
    $p = $script:GangplankPresence
    if (-not $TabId -or $TabId -notmatch '^[A-Za-z0-9_-]{1,64}$') { $TabId = 'default' }
    if (-not $p.Tabs.ContainsKey($TabId)) {
        # Bounded: forget tabs that have been gone for a while, then the oldest.
        if ($p.Tabs.Count -ge 32) {
            foreach ($key in @($p.Tabs.Keys)) {
                if ($Now -ge ((Get-GangplankTabDeadline -Tab $p.Tabs[$key]) + $p.Timeout)) { $p.Tabs.Remove($key) }
            }
        }
        while ($p.Tabs.Count -ge 32) {
            $oldest = @($p.Tabs.Keys | Sort-Object { [DateTime]$p.Tabs[$_].Seen })[0]
            $p.Tabs.Remove($oldest)
        }
        $p.Tabs[$TabId] = @{ Seen = $Now; LeavingAt = $null }
    }
    $tab = $p.Tabs[$TabId]
    if ($Leaving) { $tab.LeavingAt = $Now }
    else { $tab.Seen = $Now; $tab.LeavingAt = $null }
    $p.EverSeen = $true
}

function Register-GangplankRequestFinished {
    <#
      The host handles one request at a time. Long work runs as background jobs, but a
      request answered on the loop can still take seconds (a provider read with a 20 s
      timeout); heartbeats sent meanwhile wait in the listener queue. After such a
      request, give them the leaving grace to arrive before deciding the tab is gone.
    #>
    param([DateTime]$Now = [DateTime]::UtcNow)
    if ($null -eq $script:GangplankPresence) { return }
    $script:GangplankPresence.BusyUntil = $Now + $script:GangplankPresence.Grace
}

function Test-GangplankBrowserGone {
    <# True when auto-stop is on, a tab was seen, and every tab is past its deadline. #>
    param([DateTime]$Now = [DateTime]::UtcNow)
    $p = $script:GangplankPresence
    if ($null -eq $p -or -not $p.AutoStop -or -not $p.EverSeen) { return $false }
    if ($null -ne $p.BusyUntil -and $Now -lt [DateTime]$p.BusyUntil) { return $false }
    foreach ($tab in @($p.Tabs.Values)) {
        if ($Now -lt (Get-GangplankTabDeadline -Tab $tab)) { return $false }
    }
    return $true
}

function Get-GangplankPresenceState {
    param([DateTime]$Now = [DateTime]::UtcNow)
    $p = $script:GangplankPresence
    if ($null -eq $p) { return @{ autoStop = $false; tabs = 0 } }
    $alive = 0
    foreach ($tab in @($p.Tabs.Values)) { if ($null -eq $tab.LeavingAt -and $Now -lt (Get-GangplankTabDeadline -Tab $tab)) { $alive++ } }
    return @{
        autoStop = [bool]$p.AutoStop
        tabs = $alive
        timeoutSeconds = [int]$p.Timeout.TotalSeconds
        leavingGraceSeconds = [int]$p.Grace.TotalSeconds
    }
}

function Test-GangplankAutoStopEnabled {
    <#
      -Stay, GANGPLANK_AUTO_STOP=0 (environment) or "AutoStop": false in
      config\gangplank-config.json turn auto-stop off. GANGPLANK_AUTO_STOP=1 forces it on.
    #>
    param([switch]$Stay, [object]$Config)
    if ($Stay) { return $false }
    # GANGPLANK_AUTO_STOP, then the pre-rename KEYSTONE_AUTO_STOP (inline: this file
    # is also used without the module).
    $flag = [string]$env:GANGPLANK_AUTO_STOP
    if ([string]::IsNullOrWhiteSpace($flag)) { $flag = [string]$env:KEYSTONE_AUTO_STOP }
    if ($flag) {
        if ($flag.Trim() -in @('0','false','off','no')) { return $false }
        if ($flag.Trim() -in @('1','true','on','yes')) { return $true }
    }
    if ($null -ne $Config -and $Config.PSObject.Properties['AutoStop'] -and $Config.AutoStop -eq $false) { return $false }
    return $true
}

function Get-GangplankFullPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    try { return [IO.Path]::GetFullPath($Path).TrimEnd('\','/') } catch { return $Path.TrimEnd('\','/') }
}

function ConvertTo-GangplankCurrentStateRoot {
    <#
      A Keystone-era saved-session folder (%LOCALAPPDATA%\Keystone or <WorkRoot>\.keystone)
      is the same session as its Gangplank successor (the folder is copied forward on
      first launch), so an older Keystone host still counts as "already running".
    #>
    param([string]$Path)
    $full = Get-GangplankFullPath $Path
    if (-not $full) { return '' }
    $leaf = [IO.Path]::GetFileName($full)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ($leaf -ieq 'Keystone') { return [IO.Path]::Combine($parent, 'Gangplank') }
    if ($leaf -ieq '.keystone') { return [IO.Path]::Combine($parent, '.gangplank') }
    return $full
}

function Test-GangplankSameStateRoot {
    <# Same saved-session folder? Windows paths compare case-insensitively. #>
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals((ConvertTo-GangplankCurrentStateRoot $A), (ConvertTo-GangplankCurrentStateRoot $B), [StringComparison]::OrdinalIgnoreCase)
}

function Get-GangplankCommandLineStateRoot {
    <#
      The saved-session folder a Start-Gangplank.ps1 command line uses: <WorkRoot>\.gangplank
      with -WorkRoot, otherwise %LOCALAPPDATA%\Gangplank (same user, so the same variable).
    #>
    param([string]$CommandLine)
    # A Keystone-era host (Start-KeystoneWeb.ps1) used the Keystone folder names.
    $legacy = ([string]$CommandLine -match '(?i)Start-KeystoneWeb\.ps1')
    $m = [regex]::Match([string]$CommandLine, '(?i)-WorkRoot\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
    if ($m.Success) {
        $w = $m.Groups[1].Value; if (-not $w) { $w = $m.Groups[2].Value }; if (-not $w) { $w = $m.Groups[3].Value }
        # [IO.Path]::Combine: Join-Path would fail for a drive that does not exist here.
        return [IO.Path]::Combine($w, $(if ($legacy) { '.keystone' } else { '.gangplank' }))
    }
    $appData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:HOME) { Join-Path $env:HOME '.local/share' } else { [IO.Path]::GetTempPath() }
    return (Join-Path $appData $(if ($legacy) { 'Keystone' } else { 'Gangplank' }))
}

# ---------- data folders from before the rename (Keystone -> Gangplank) ----------

function Copy-GangplankLegacyStateFolder {
    <#
      One-time, idempotent copy of a Keystone-era data folder (%LOCALAPPDATA%\Keystone or
      <WorkRoot>\.keystone: saved session, sealed credentials, LocalDev config) to its
      Gangplank name. Runs only when the new folder does not exist yet and the old one
      does; the old folder is left untouched, so an older Keystone still works. Copies
      into a temporary sibling first and renames it, so an interrupted copy is retried
      on the next launch instead of leaving a half-filled folder behind.
      Returns $true when it copied.
    #>
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    if (Test-Path -LiteralPath $To) { return $false }
    if (-not (Test-Path -LiteralPath $From -PathType Container)) { return $false }
    $parent = Split-Path $To -Parent
    $tmp = Join-Path $parent ('.' + (Split-Path $To -Leaf) + '-migrating-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        Copy-Item -LiteralPath $From -Destination $tmp -Recurse -Force -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $To -ErrorAction Stop
        return $true
    } catch {
        Write-Warning ('Could not copy ' + $From + ' to ' + $To + ': ' + $_.Exception.Message + ' Gangplank starts without the earlier session.')
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------- runtime files: Logs\gangplank-server-<pid>.json ----------

function Get-GangplankRuntimeDirectory {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root 'Logs')
}

function Write-GangplankRuntimeFile {
    <#
      pid, port, url, start time and the saved-session folder only; never the launch
      link, cookie or client secret. Returns the path.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url, [string]$StateRoot)
    $dir = Get-GangplankRuntimeDirectory -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ('gangplank-server-{0}.json' -f $PID)
    $info = [ordered]@{
        pid = $PID
        port = $Port
        url = $Url
        startedAt = [DateTime]::UtcNow.ToString('o')
        stateRoot = (Get-GangplankFullPath $StateRoot)
    }
    $json = $info | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Remove-GangplankRuntimeFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

# ---------- finding and stopping running hosts ----------

function Get-GangplankServerProcesses {
    <#
    .SYNOPSIS
      Running Gangplank web hosts: from the runtime files under <Root>\Logs, then any
      PowerShell whose command line runs Start-Gangplank.ps1. Stale runtime files
      (dead pid, or the pid now belongs to something else) are deleted.
    .PARAMETER ThisCheckout
      Only hosts started from this folder: the launcher's single-instance check uses
      this, so a test run in another checkout never stops your real session.
    .PARAMETER StateRoot
      Only hosts using this saved-session folder (the launcher's single-instance
      check). Two hosts may run side by side on different ports; two hosts sharing
      one saved session may not. Tests and LocalDev use their own -WorkRoot, so they
      never stop your real session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$ThisCheckout, [string]$StateRoot)
    $found = @{}
    $otherSession = @{}
    $dir = Get-GangplankRuntimeDirectory -Root $Root
    if (Test-Path -LiteralPath $dir) {
        # keystone-server-*.json: hosts started before the rename (Keystone) are found too.
        $runtimeFiles = @(Get-ChildItem -LiteralPath $dir -Filter 'gangplank-server-*.json' -File -ErrorAction SilentlyContinue) +
                        @(Get-ChildItem -LiteralPath $dir -Filter 'keystone-server-*.json' -File -ErrorAction SilentlyContinue)
        foreach ($f in $runtimeFiles) {
            try {
                $info = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                $id = [int]$info.pid
                $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
                $live = ($id -ne $PID -and $proc -and $proc.ProcessName -match '^(powershell|pwsh)$')
                if ($live -and $info.startedAt) {
                    # The pid was reused by a PowerShell started after the host wrote this file.
                    try {
                        if ($info.startedAt -is [DateTime]) { $written = ([DateTime]$info.startedAt).ToUniversalTime() }
                        else { $written = [DateTime]::Parse([string]$info.startedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
                        if ($proc.StartTime.ToUniversalTime() -gt $written.AddSeconds(5)) { $live = $false }
                    } catch { }
                }
                if ($live -and $StateRoot -and $info.PSObject.Properties['stateRoot'] -and $info.stateRoot -and -not (Test-GangplankSameStateRoot $StateRoot ([string]$info.stateRoot))) {
                    $otherSession[$id] = $true
                } elseif ($live) {
                    $found[$id] = [pscustomobject]@{ Pid = $id; Port = $info.port; Url = [string]$info.url; Started = $info.startedAt; RuntimeFile = $f.FullName }
                } elseif ($id -ne $PID) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $hostScripts = @((Join-Path $Root 'Start-Gangplank.ps1'), (Join-Path $Root 'Start-KeystoneWeb.ps1'))
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)
        foreach ($row in $rows) {
            $id = [int]$row.ProcessId
            $cmd = [string]$row.CommandLine
            if ($id -eq $PID -or $found.ContainsKey($id) -or $otherSession.ContainsKey($id) -or -not $cmd) { continue }
            # Start-KeystoneWeb.ps1: a host from before the rename (Keystone).
            if ($cmd -notmatch '(?i)Start-(Gangplank|KeystoneWeb)\.ps1') { continue }
            if ($ThisCheckout -and -not @($hostScripts | Where-Object { $cmd.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { continue }
            if ($StateRoot -and -not (Test-GangplankSameStateRoot $StateRoot (Get-GangplankCommandLineStateRoot -CommandLine $cmd))) { continue }
            $found[$id] = [pscustomobject]@{ Pid = $id; Port = $null; Url = $null; Started = $row.CreationDate; RuntimeFile = $null }
        }
    } catch { }   # no CIM (non-Windows) or no permission: the runtime files are still used
    return @($found.Values | Sort-Object Pid)
}

function Get-GangplankStopEventName {
    # -Legacy: the name a Keystone-era host listens on.
    param([Parameter(Mandatory)][int]$ProcessId, [switch]$Legacy)
    if ($Legacy) { return ('Local\Keystone-Stop-{0}' -f $ProcessId) }
    return ('Local\Gangplank-Stop-{0}' -f $ProcessId)
}

function New-GangplankStopEvent {
    <#
      A named event other processes set to ask this host to stop cleanly (between
      requests, so never during a save; the finally block then removes the runtime
      file). Returns $null where named events are not supported.
    #>
    try {
        return (New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, (Get-GangplankStopEventName -ProcessId $PID)))
    } catch { return $null }
}

function Request-GangplankServerStop {
    <#
      Sets the host's stop event: the Gangplank name, then the Keystone name an older
      host listens on. False when it has neither (very old host, or not a host).
    #>
    param([Parameter(Mandatory)][int]$ProcessId)
    foreach ($legacy in @($false,$true)) {
        $handle = $null
        try {
            $handle = [Threading.EventWaitHandle]::OpenExisting((Get-GangplankStopEventName -ProcessId $ProcessId -Legacy:$legacy))
            [void]$handle.Set()
            return $true
        } catch {
        } finally {
            if ($handle) { $handle.Dispose() }
        }
    }
    return $false
}

function Stop-GangplankServerProcesses {
    <#
    .SYNOPSIS
      Stops every running Gangplank web host found by Get-GangplankServerProcesses and
      returns what it stopped (Pid, Url). Each host is first asked to stop cleanly
      (it finishes the request it is serving); after -GraceSeconds it is killed.
      Access denied (an elevated window) is reported as a warning, not thrown.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$ThisCheckout, [string]$StateRoot, [int]$GraceSeconds = 30)
    $stopped = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-GangplankServerProcesses -Root $Root -ThisCheckout:$ThisCheckout -StateRoot $StateRoot)) {
        $proc = Get-Process -Id $p.Pid -ErrorAction SilentlyContinue
        if (-not $proc) { Remove-GangplankRuntimeFile -Path $p.RuntimeFile; continue }
        $clean = $false
        if (Request-GangplankServerStop -ProcessId $p.Pid) {
            # Wait for the process to exit, or (a host run inside someone's own PowerShell
            # window) for it to delete its runtime file and return to the prompt.
            $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($proc.HasExited) { $clean = $true; break }
                if ($p.RuntimeFile -and -not (Test-Path -LiteralPath $p.RuntimeFile)) { $clean = $true; break }
                Start-Sleep -Milliseconds 200
                $proc.Refresh()
            }
        }
        if (-not $clean -and (Get-Process -Id $p.Pid -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $p.Pid -Force -ErrorAction Stop
                try { [void]$proc.WaitForExit(5000) } catch { }
            } catch {
                if (Get-Process -Id $p.Pid -ErrorAction SilentlyContinue) {
                    Write-Warning ('Could not stop Gangplank PID ' + $p.Pid + ': ' + $_.Exception.Message + ' If it runs as administrator, stop it from an administrator PowerShell.')
                    continue
                }
            }
        }
        # A killed host cannot delete its own runtime file.
        Remove-GangplankRuntimeFile -Path $p.RuntimeFile
        $stopped.Add($p)
    }
    return $stopped.ToArray()
}

function Format-GangplankServerProcess {
    param([Parameter(Mandatory)]$Process)
    if ($Process.Url) { return ('PID {0} ({1})' -f $Process.Pid, $Process.Url) }
    return ('PID {0}' -f $Process.Pid)
}
