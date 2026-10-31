#Requires -Version 5.1
# =============================================================================
# Background jobs (pattern: Halyard Host/JobManager.cs).
# Long work (connect, download, save, review, AI) runs in its own runspace so
# the sequential HTTP loop keeps answering. A job:
#   * imports the Gangplank module fresh and calls ONE named module function;
#   * gets plain data in (session snapshot, token) and returns plain data out;
#   * reports progress / streamed text through a synchronized hashtable;
#   * is finished on the main thread (OnComplete), which is the only place the
#     live session is changed.
# One running job per group: 'workspace' jobs never overlap each other.
# =============================================================================

$script:GangplankJobs = [ordered]@{}
$script:GangplankJobKeep = 40

function Start-GangplankJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Function,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnComplete = $null,
        [hashtable]$Context = @{}
    )
    foreach ($j in $script:GangplankJobs.Values) {
        # A cancelled job may still be inside a blocking request: it stays busy until it ends.
        if ($j.Group -eq $Group -and $j.State -in @('running','cancelling')) {
            throw "BUSY|Gangplank is still working on '$($j.Kind)'. Wait for it to finish."
        }
    }
    $shared = [hashtable]::Synchronized(@{ Progress = 'Starting'; Chunks = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)) })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $bootstrap = {
        param($ModulePath,$LogDir,$ConfigPath,$Function,$Shared,$Arguments)
        $ErrorActionPreference = 'Stop'
        Import-Module $ModulePath -Force -WarningAction SilentlyContinue
        & (Get-Module Gangplank) {
            param($LogDir,$ConfigPath,$Function,$Shared,$Arguments)
            Initialize-GangplankLogging -LogDir $LogDir -Level INFO
            Initialize-GangplankConfig -ConfigPath $ConfigPath
            if ($Arguments.ContainsKey('DevGitHubUrl') -and $Arguments.DevGitHubUrl) { Set-GangplankDevProvider -GitHubUrl $Arguments.DevGitHubUrl }
            if ($Arguments.ContainsKey('DevGitLabUrl') -and $Arguments.DevGitLabUrl) { Set-GangplankDevProvider -GitLabUrl $Arguments.DevGitLabUrl }
            & $Function -Shared $Shared -Arguments $Arguments
        } $LogDir $ConfigPath $Function $Shared $Arguments
    }
    [void]$ps.AddScript($bootstrap.ToString()).AddArgument((Join-Path $script:GangplankRoot 'Gangplank.psm1')).AddArgument($script:GangplankLogDir).AddArgument($script:GangplankConfigPath).AddArgument($Function).AddArgument($shared).AddArgument($Arguments)
    $id = 'job-' + [guid]::NewGuid().ToString('N').Substring(0,12)
    $job = [ordered]@{
        Id = $id; Kind = $Kind; Group = $Group; State = 'running'
        Started = (Get-Date).ToUniversalTime().ToString('o'); Finished = ''
        Shared = $shared; PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke()
        OnComplete = $OnComplete; Context = $Context; Result = $null; Error = ''
    }
    $script:GangplankJobs[$id] = $job
    Write-GangplankLog -Level INFO -Message "Job $id started: $Kind"
    Remove-GangplankOldJobs
    return $id
}

function Get-GangplankJobErrorMessage {
    param($ErrorRecordOrException)
    $e = $ErrorRecordOrException
    if ($e -is [Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e -and ($e -is [Management.Automation.MethodInvocationException] -or $e -is [Management.Automation.CmdletInvocationException]) -and $e.InnerException) { $e = $e.InnerException }
    if (-not $e) { return 'The job failed.' }
    return (Get-GangplankSafeErrorMessage -Message $e.Message)
}

function Update-GangplankJobs {
    # Called from the HTTP loop on the main thread: finish completed jobs.
    foreach ($job in @($script:GangplankJobs.Values)) {
        if ($job.State -notin @('running','cancelling') -or -not $job.Handle -or -not $job.Handle.IsCompleted) { continue }
        $wasCancelling = ($job.State -eq 'cancelling')
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.Streams.Error.Count -gt 0 -and $job.PowerShell.HadErrors -and @($output).Count -eq 0) {
                throw $job.PowerShell.Streams.Error[0].Exception
            }
            $result = if (@($output).Count -gt 0) { @($output)[-1] } else { $null }
            # OnComplete runs here, on the main thread, with plain data only. It is
            # a plain module scriptblock (no GetNewClosure, which would detach it
            # from the module); per-job values come through Context.
            if ($job.OnComplete) {
                # The remote work is done (even if a cancel arrived too late to stop it).
                # A failure applying it locally (state file, credential gone) must not
                # turn a completed write into "failed".
                try { $result = & $job.OnComplete $result $job.Context }
                catch { Write-GangplankLog -Level WARN -Message "Job $($job.Id) finished but its result could not be applied: $($_.Exception.Message)" }
            }
            $job.Result = $result
            $job.State = 'succeeded'
        } catch {
            $job.Error = Get-GangplankJobErrorMessage $_
            $job.State = $(if ($wasCancelling) { 'cancelled' } else { 'failed' })
            Write-GangplankLog -Level WARN -Message "Job $($job.Id) ($($job.Kind)) failed: $($_.Exception.Message)"
        } finally {
            $job.Finished = (Get-Date).ToUniversalTime().ToString('o')
            try { $job.PowerShell.Dispose() } catch { }
            try { $job.Runspace.Dispose() } catch { }
            $job.PowerShell = $null; $job.Runspace = $null; $job.Handle = $null
        }
    }
}

function Test-GangplankJobsBusy {
    # True while any background job (save, download, review, AI) is still running.
    # The lifecycle never stops the host under one.
    foreach ($j in @($script:GangplankJobs.Values)) {
        if ($j.State -in @('running','cancelling')) { return $true }
    }
    return $false
}

function Stop-GangplankJob {
    param([Parameter(Mandatory)][string]$Id)
    $job = $script:GangplankJobs[$Id]
    if (-not $job) { throw 'NOT_FOUND|No such job.' }
    if ($job.State -ne 'running') { return $false }
    $job.State = 'cancelling'
    try { [void]$job.PowerShell.BeginStop($null,$null) } catch { }
    return $true
}

function Wait-GangplankJob {
    # For tests and the CLI: block until the job finishes (main thread).
    param([Parameter(Mandatory)][string]$Id,[int]$TimeoutSec = 120)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Update-GangplankJobs
        $job = $script:GangplankJobs[$Id]
        if ($job.State -notin @('running','cancelling')) { return (Get-GangplankJobView -Id $Id) }
        Start-Sleep -Milliseconds 50
    }
    throw "TIMEOUT|Job $Id did not finish in $TimeoutSec s."
}

function Get-GangplankJobView {
    param([Parameter(Mandatory)][string]$Id,[int]$After = 0)
    $job = $script:GangplankJobs[$Id]
    if (-not $job) { throw 'NOT_FOUND|No such job.' }
    $chunks = @()
    if ($After -lt 0) { $After = 0 }
    # Copy under the list's lock: the job may append while we read.
    $list = $job.Shared.Chunks
    $count = 0
    [Threading.Monitor]::Enter($list.SyncRoot)
    try {
        $count = $list.Count
        if ($After -lt $count) { $chunks = @($list.GetRange($After, $count - $After).ToArray()) }
    } finally { [Threading.Monitor]::Exit($list.SyncRoot) }
    return [ordered]@{
        id = $job.Id; kind = $job.Kind; state = $job.State
        progress = [string]$job.Shared.Progress
        chunks = $chunks; next = $count
        result = $job.Result; error = $job.Error
        started = $job.Started; finished = $job.Finished
    }
}

function Remove-GangplankOldJobs {
    $done = @($script:GangplankJobs.Values | Where-Object { $_.State -notin @('running','cancelling') })
    $excess = $script:GangplankJobs.Count - $script:GangplankJobKeep
    foreach ($j in $done) {
        if ($excess -le 0) { break }
        $script:GangplankJobs.Remove($j.Id)
        $excess--
    }
}

function Set-GangplankJobProgress {
    # Used inside job functions.
    param($Shared,[string]$Message)
    if ($Shared) { $Shared.Progress = $Message }
}
