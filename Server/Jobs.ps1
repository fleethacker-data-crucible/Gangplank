#Requires -Version 5.1
# =============================================================================
# Background jobs (pattern: Cascade Host/JobManager.cs).
# Long work (connect, download, save, review, AI) runs in its own runspace so
# the sequential HTTP loop keeps answering. A job:
#   * imports the Keystone module fresh and calls ONE named module function;
#   * gets plain data in (session snapshot, token) and returns plain data out;
#   * reports progress / streamed text through a synchronized hashtable;
#   * is finished on the main thread (OnComplete), which is the only place the
#     live session is changed.
# One running job per group: 'workspace' jobs never overlap each other.
# =============================================================================

$script:KeystoneJobs = [ordered]@{}
$script:KeystoneJobKeep = 40

function Start-KeystoneJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Function,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnComplete = $null,
        [hashtable]$Context = @{}
    )
    foreach ($j in $script:KeystoneJobs.Values) {
        if ($j.Group -eq $Group -and $j.State -eq 'running') {
            throw "BUSY|Keystone is still working on '$($j.Kind)'. Wait for it to finish."
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
        & (Get-Module Keystone) {
            param($LogDir,$ConfigPath,$Function,$Shared,$Arguments)
            Initialize-KeystoneLogging -LogDir $LogDir -Level INFO
            Initialize-KeystoneConfig -ConfigPath $ConfigPath
            if ($Arguments.ContainsKey('DevGitHubUrl') -and $Arguments.DevGitHubUrl) { Set-KeystoneDevProvider -GitHubUrl $Arguments.DevGitHubUrl }
            & $Function -Shared $Shared -Arguments $Arguments
        } $LogDir $ConfigPath $Function $Shared $Arguments
    }
    [void]$ps.AddScript($bootstrap.ToString()).AddArgument((Join-Path $script:KeystoneRoot 'Keystone.psm1')).AddArgument($script:KeystoneLogDir).AddArgument($script:KeystoneConfigPath).AddArgument($Function).AddArgument($shared).AddArgument($Arguments)
    $id = 'job-' + [guid]::NewGuid().ToString('N').Substring(0,12)
    $job = [ordered]@{
        Id = $id; Kind = $Kind; Group = $Group; State = 'running'
        Started = (Get-Date).ToUniversalTime().ToString('o'); Finished = ''
        Shared = $shared; PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke()
        OnComplete = $OnComplete; Context = $Context; Result = $null; Error = ''
    }
    $script:KeystoneJobs[$id] = $job
    Write-KeystoneLog -Level INFO -Message "Job $id started: $Kind"
    Remove-KeystoneOldJobs
    return $id
}

function Get-KeystoneJobErrorMessage {
    param($ErrorRecordOrException)
    $e = $ErrorRecordOrException
    if ($e -is [Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e -and ($e -is [Management.Automation.MethodInvocationException] -or $e -is [Management.Automation.CmdletInvocationException]) -and $e.InnerException) { $e = $e.InnerException }
    if (-not $e) { return 'The job failed.' }
    return (Get-KeystoneSafeErrorMessage -Message $e.Message)
}

function Update-KeystoneJobs {
    # Called from the HTTP loop on the main thread: finish completed jobs.
    foreach ($job in @($script:KeystoneJobs.Values)) {
        if ($job.State -ne 'running' -or -not $job.Handle.IsCompleted) { continue }
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.Streams.Error.Count -gt 0 -and $job.PowerShell.HadErrors -and @($output).Count -eq 0) {
                throw $job.PowerShell.Streams.Error[0].Exception
            }
            $result = if (@($output).Count -gt 0) { @($output)[-1] } else { $null }
            # OnComplete runs here, on the main thread, with plain data only. It is
            # a plain module scriptblock (no GetNewClosure, which would detach it
            # from the module); per-job values come through Context.
            if ($job.OnComplete) { $result = & $job.OnComplete $result $job.Context }
            $job.Result = $result
            $job.State = 'succeeded'
        } catch {
            $job.Error = Get-KeystoneJobErrorMessage $_
            $job.State = $(if ($job.State -eq 'cancelling') { 'cancelled' } else { 'failed' })
            Write-KeystoneLog -Level WARN -Message "Job $($job.Id) ($($job.Kind)) failed: $($_.Exception.Message)"
        } finally {
            $job.Finished = (Get-Date).ToUniversalTime().ToString('o')
            try { $job.PowerShell.Dispose() } catch { }
            try { $job.Runspace.Dispose() } catch { }
            $job.PowerShell = $null; $job.Runspace = $null; $job.Handle = $null
        }
    }
}

function Stop-KeystoneJob {
    param([Parameter(Mandatory)][string]$Id)
    $job = $script:KeystoneJobs[$Id]
    if (-not $job) { throw 'NOT_FOUND|No such job.' }
    if ($job.State -ne 'running') { return $false }
    $job.State = 'cancelling'
    try { [void]$job.PowerShell.BeginStop($null,$null) } catch { }
    return $true
}

function Wait-KeystoneJob {
    # For tests and the CLI: block until the job finishes (main thread).
    param([Parameter(Mandatory)][string]$Id,[int]$TimeoutSec = 120)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Update-KeystoneJobs
        $job = $script:KeystoneJobs[$Id]
        if ($job.State -notin @('running','cancelling')) { return (Get-KeystoneJobView -Id $Id) }
        Start-Sleep -Milliseconds 50
    }
    throw "TIMEOUT|Job $Id did not finish in $TimeoutSec s."
}

function Get-KeystoneJobView {
    param([Parameter(Mandatory)][string]$Id,[int]$After = 0)
    $job = $script:KeystoneJobs[$Id]
    if (-not $job) { throw 'NOT_FOUND|No such job.' }
    $chunks = @()
    $count = $job.Shared.Chunks.Count
    if ($After -lt 0) { $After = 0 }
    if ($After -lt $count) { $chunks = @($job.Shared.Chunks.GetRange($After, $count - $After)) }
    return [ordered]@{
        id = $job.Id; kind = $job.Kind; state = $job.State
        progress = [string]$job.Shared.Progress
        chunks = $chunks; next = $count
        result = $job.Result; error = $job.Error
        started = $job.Started; finished = $job.Finished
    }
}

function Remove-KeystoneOldJobs {
    $done = @($script:KeystoneJobs.Values | Where-Object { $_.State -notin @('running','cancelling') })
    $excess = $script:KeystoneJobs.Count - $script:KeystoneJobKeep
    foreach ($j in $done) {
        if ($excess -le 0) { break }
        $script:KeystoneJobs.Remove($j.Id)
        $excess--
    }
}

function Set-KeystoneJobProgress {
    # Used inside job functions.
    param($Shared,[string]$Message)
    if ($Shared) { $Shared.Progress = $Message }
}
