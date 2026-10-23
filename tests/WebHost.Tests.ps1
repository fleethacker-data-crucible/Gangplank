#Requires -Version 5.1
# Windows-only localhost smoke test. Does not use credentials or remote services.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$port = Get-Random -Minimum 19000 -Maximum 29000
$url = "http://localhost:$port/"
# Test the same BAT entrypoint users double-click, not just the PS1 host.
$launcher = Join-Path $root 'Launch-Keystone.bat'
$batchText = [IO.File]::ReadAllText($launcher)
if ($batchText -notmatch '(?i)-ExecutionPolicy\s+Bypass') { throw 'Keystone launcher is missing the process-scoped execution-policy option used by ARC/Cascade.' }
if ($batchText -notmatch '(?i)-STA') { throw 'Keystone launcher is missing the STA option needed for ARC UI compatibility.' }
$args = ('/d /c ""{0}" -NoBrowser {1}"' -f $launcher,$port)
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
try {
    $response = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
            break
        } catch {
            if ($process.HasExited) { throw "Keystone web host exited unexpectedly: $($process.ExitCode)" }
        }
    }
    if (-not $response -or $response.StatusCode -ne 200) { throw 'Local web host did not respond.' }
    if ($response.Content -notmatch "const CSRF='([^']+)'") { throw 'Browser page has no CSRF bootstrap.' }
    $csrf = $Matches[1]
    if ($csrf -eq '__KEYSTONE_CSRF__' -or $csrf.Length -lt 20) { throw 'CSRF token not generated.' }
    $status = Invoke-RestMethod -Uri ($url + 'api/status') -TimeoutSec 3
    $integration = Invoke-RestMethod -Uri ($url + 'api/integrations') -TimeoutSec 3
    if ($null -eq $integration.arcLoaded -or @($integration.integrations).Count -lt 2) {
        throw 'Localhost ARC integrations status endpoint is missing provider metadata.'
    }
    $publicJson = $integration | ConvertTo-Json -Depth 6
    if ($publicJson -match 'Authorization:|Bearer\s+[A-Za-z0-9]+') {
        throw 'Integrations endpoint leaked authorization text.'
    }
    if ($status.connected) { throw 'Fresh workspace unexpectedly has a remote session.' }
    $failedAsExpected = $false
    try {
        Invoke-RestMethod -Method Post -Uri ($url + 'api/connect') -ContentType 'application/json' -Body '{"url":"https://github.com/a/b"}' -TimeoutSec 4 | Out-Null
    } catch {
        if ([int]$_.Exception.Response.StatusCode -eq 403) { $failedAsExpected = $true }
    }
    if (-not $failedAsExpected) { throw 'CSRF-free POST was not rejected.' }
    $rejectedHost = $false
    try {
        Invoke-RestMethod -Method Post -Uri ($url + 'api/connect') -Headers @{ 'X-Keystone-Session' = $csrf } -ContentType 'application/json' -Body '{"url":"https://untrusted.invalid/a/b"}' -TimeoutSec 4 | Out-Null
    } catch {
        if ([int]$_.Exception.Response.StatusCode -eq 400) { $rejectedHost = $true }
    }
    if (-not $rejectedHost) { throw 'Untrusted repository hostname was not rejected.' }
    Write-Host 'Localhost browser host, status, CSRF and URL controls passed.' -ForegroundColor Green
} finally {
    if ($process -and -not $process.HasExited) {
        # Kill the cmd.exe launcher and its child PowerShell process to avoid orphan servers.
        & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}
