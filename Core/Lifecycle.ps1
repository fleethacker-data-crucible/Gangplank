#Requires -Version 5.1
# ============================================================
#  Core/Lifecycle.ps1 - browser presence, runtime files, and
#  finding / stopping running Keystone web hosts.
#
#  Dot-sourced by Start-KeystoneWeb.ps1, Stop-Keystone.ps1 and
#  tests. Not loaded by Keystone.psm1: the CLI has no server.
#  Needs nothing else from Keystone, so Stop-Keystone.ps1 can
#  use it without importing the module.
# ============================================================

$script:KeystonePresence = $null

# ---------- presence: the browser tab owns the server ----------
# The UI sends POST /api/heartbeat every 5 s, and a "leaving" beacon on pagehide.
# Each tab sends its own random id, so with two tabs open, closing one does not stop
# the host. A tab is gone 20 s after its last heartbeat, or 5 s after its leaving
# signal (a reload sends a new heartbeat from a new tab id well inside that).
# The host stops when every tab it has seen is gone. Until the first heartbeat
# nothing stops (-NoBrowser, diagnostics, CI).

function Reset-KeystonePresence {
    param(
        [bool]$AutoStop = $true,
        [int]$TimeoutSeconds = 20,
        [int]$LeavingGraceSeconds = 5
    )
    $script:KeystonePresence = @{
        AutoStop  = $AutoStop
        Timeout   = [TimeSpan]::FromSeconds($TimeoutSeconds)
        Grace     = [TimeSpan]::FromSeconds($LeavingGraceSeconds)
        Tabs      = @{}
        EverSeen  = $false
        BusyUntil = $null
    }
}

function Get-KeystoneTabDeadline {
    param([Parameter(Mandatory)][hashtable]$Tab)
    $p = $script:KeystonePresence
    if ($null -ne $Tab.LeavingAt) { return ([DateTime]$Tab.LeavingAt) + $p.Grace }
    return ([DateTime]$Tab.Seen) + $p.Timeout
}

function Register-KeystonePresence {
    <# Records a heartbeat (or, with -Leaving, the tab's unload signal). #>
    param(
        [string]$TabId,
        [switch]$Leaving,
        [DateTime]$Now = [DateTime]::UtcNow
    )
    if ($null -eq $script:KeystonePresence) { Reset-KeystonePresence }
    $p = $script:KeystonePresence
    if (-not $TabId -or $TabId -notmatch '^[A-Za-z0-9_-]{1,64}$') { $TabId = 'default' }
    if (-not $p.Tabs.ContainsKey($TabId)) {
        # Bounded: forget tabs that have been gone for a while, then the oldest.
        if ($p.Tabs.Count -ge 32) {
            foreach ($key in @($p.Tabs.Keys)) {
                if ($Now -ge ((Get-KeystoneTabDeadline -Tab $p.Tabs[$key]) + $p.Timeout)) { $p.Tabs.Remove($key) }
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

function Register-KeystoneRequestFinished {
    <#
      The host handles one request at a time, so heartbeats sent while a long request
      (save, download, AI stream) runs wait in the HttpListener queue. After such a
      request, give them the leaving grace to arrive before deciding the tab is gone.
    #>
    param([DateTime]$Now = [DateTime]::UtcNow)
    if ($null -eq $script:KeystonePresence) { return }
    $script:KeystonePresence.BusyUntil = $Now + $script:KeystonePresence.Grace
}

function Test-KeystoneBrowserGone {
    <# True when auto-stop is on, a tab was seen, and every tab is past its deadline. #>
    param([DateTime]$Now = [DateTime]::UtcNow)
    $p = $script:KeystonePresence
    if ($null -eq $p -or -not $p.AutoStop -or -not $p.EverSeen) { return $false }
    if ($null -ne $p.BusyUntil -and $Now -lt [DateTime]$p.BusyUntil) { return $false }
    foreach ($tab in @($p.Tabs.Values)) {
        if ($Now -lt (Get-KeystoneTabDeadline -Tab $tab)) { return $false }
    }
    return $true
}

function Get-KeystonePresenceState {
    param([DateTime]$Now = [DateTime]::UtcNow)
    $p = $script:KeystonePresence
    if ($null -eq $p) { return @{ autoStop = $false; tabs = 0 } }
    $alive = 0
    foreach ($tab in @($p.Tabs.Values)) { if ($null -eq $tab.LeavingAt -and $Now -lt (Get-KeystoneTabDeadline -Tab $tab)) { $alive++ } }
    return @{
        autoStop = [bool]$p.AutoStop
        tabs = $alive
        timeoutSeconds = [int]$p.Timeout.TotalSeconds
        leavingGraceSeconds = [int]$p.Grace.TotalSeconds
    }
}

function Test-KeystoneAutoStopEnabled {
    <#
      -Stay, KEYSTONE_AUTO_STOP=0 (environment) or "AutoStop": false in
      config\keystone-config.json turn auto-stop off. KEYSTONE_AUTO_STOP=1 forces it on.
    #>
    param([switch]$Stay, [object]$Config)
    if ($Stay) { return $false }
    $flag = [string]$env:KEYSTONE_AUTO_STOP
    if ($flag) {
        if ($flag.Trim() -in @('0','false','off','no')) { return $false }
        if ($flag.Trim() -in @('1','true','on','yes')) { return $true }
    }
    if ($null -ne $Config -and $Config.PSObject.Properties['AutoStop'] -and $Config.AutoStop -eq $false) { return $false }
    return $true
}

# ---------- runtime files: Logs\keystone-server-<pid>.json ----------

function Get-KeystoneRuntimeDirectory {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root 'Logs')
}

function Write-KeystoneRuntimeFile {
    <# pid, port, url and start time only; never the session (CSRF) token. Returns the path. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url)
    $dir = Get-KeystoneRuntimeDirectory -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ('keystone-server-{0}.json' -f $PID)
    $info = [ordered]@{
        pid = $PID
        port = $Port
        url = $Url
        startedAt = [DateTime]::UtcNow.ToString('o')
    }
    $json = $info | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Remove-KeystoneRuntimeFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

# ---------- finding and stopping running hosts ----------

function Get-KeystoneServerProcesses {
    <#
    .SYNOPSIS
      Running Keystone web hosts: from the runtime files under <Root>\Logs, then any
      PowerShell whose command line runs Start-KeystoneWeb.ps1. Stale runtime files
      (dead pid, or the pid now belongs to something else) are deleted.
    .PARAMETER ThisCheckout
      Only hosts started from this folder: the launcher's single-instance check uses
      this, so a test run in another checkout never stops your real session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$ThisCheckout)
    $found = @{}
    $dir = Get-KeystoneRuntimeDirectory -Root $Root
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'keystone-server-*.json' -File -ErrorAction SilentlyContinue)) {
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
                if ($live) {
                    $found[$id] = [pscustomobject]@{ Pid = $id; Port = $info.port; Url = [string]$info.url; Started = $info.startedAt; RuntimeFile = $f.FullName }
                } elseif ($id -ne $PID) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $hostScript = Join-Path $Root 'Start-KeystoneWeb.ps1'
    try {
        $rows = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)
        foreach ($row in $rows) {
            $id = [int]$row.ProcessId
            $cmd = [string]$row.CommandLine
            if ($id -eq $PID -or $found.ContainsKey($id) -or -not $cmd) { continue }
            if ($cmd -notmatch 'Start-KeystoneWeb\.ps1') { continue }
            if ($ThisCheckout -and $cmd.IndexOf($hostScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $found[$id] = [pscustomobject]@{ Pid = $id; Port = $null; Url = $null; Started = $row.CreationDate; RuntimeFile = $null }
        }
    } catch { }   # no CIM (non-Windows) or no permission: the runtime files are still used
    return @($found.Values | Sort-Object Pid)
}

function Get-KeystoneStopEventName {
    param([Parameter(Mandatory)][int]$ProcessId)
    return ('Local\Keystone-Stop-{0}' -f $ProcessId)
}

function New-KeystoneStopEvent {
    <#
      A named event other processes set to ask this host to stop cleanly (between
      requests, so never during a save; the finally block then removes the runtime
      file). Returns $null where named events are not supported.
    #>
    try {
        return (New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, (Get-KeystoneStopEventName -ProcessId $PID)))
    } catch { return $null }
}

function Request-KeystoneServerStop {
    <# Sets the host's stop event. False when it has none (older Keystone, or not a host). #>
    param([Parameter(Mandatory)][int]$ProcessId)
    $handle = $null
    try {
        $handle = [Threading.EventWaitHandle]::OpenExisting((Get-KeystoneStopEventName -ProcessId $ProcessId))
        [void]$handle.Set()
        return $true
    } catch {
        return $false
    } finally {
        if ($handle) { $handle.Dispose() }
    }
}

function Stop-KeystoneServerProcesses {
    <#
    .SYNOPSIS
      Stops every running Keystone web host found by Get-KeystoneServerProcesses and
      returns what it stopped (Pid, Url). Each host is first asked to stop cleanly
      (it finishes the request it is serving); after -GraceSeconds it is killed.
      Access denied (an elevated window) is reported as a warning, not thrown.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$ThisCheckout, [int]$GraceSeconds = 30)
    $stopped = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-KeystoneServerProcesses -Root $Root -ThisCheckout:$ThisCheckout)) {
        $proc = Get-Process -Id $p.Pid -ErrorAction SilentlyContinue
        if (-not $proc) { Remove-KeystoneRuntimeFile -Path $p.RuntimeFile; continue }
        $clean = $false
        if (Request-KeystoneServerStop -ProcessId $p.Pid) {
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
                    Write-Warning ('Could not stop Keystone PID ' + $p.Pid + ': ' + $_.Exception.Message + ' If it runs as administrator, stop it from an administrator PowerShell.')
                    continue
                }
            }
        }
        # A killed host cannot delete its own runtime file.
        Remove-KeystoneRuntimeFile -Path $p.RuntimeFile
        $stopped.Add($p)
    }
    return $stopped.ToArray()
}

function Format-KeystoneServerProcess {
    param([Parameter(Mandatory)]$Process)
    if ($Process.Url) { return ('PID {0} ({1})' -f $Process.Pid, $Process.Url) }
    return ('PID {0}' -f $Process.Pid)
}
