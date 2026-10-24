#Requires -Version 5.1
# Localhost smoke test of the real host under Windows PowerShell 5.1 (pwsh elsewhere).
# LocalDev, no credentials, no remote services. The full flow against a synthetic
# GitHub is tests/e2e/host.e2e.mjs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

# The BAT entrypoint users double-click must keep its PowerShell switches.
$batchText = [IO.File]::ReadAllText((Join-Path $root 'Launch-Keystone.bat'))
Assert ($batchText -match '(?i)-ExecutionPolicy\s+Bypass') 'Keystone launcher is missing the process-scoped execution-policy option used by ARC/Cascade.'
Assert ($batchText -match '(?i)-STA') 'Keystone launcher is missing the STA option.'
Assert ($batchText -notmatch '(?i)set "ARC_PATH=') 'The launcher must not auto-configure ARC.'

$port = Get-Random -Minimum 19000 -Maximum 29000
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-webhost-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
$out = Join-Path $temp 'host.out'
$exe = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { 'powershell.exe' }
# Explicit LocalDev so an unattended runner never imports ARC or waits on an unlock prompt.
$psArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $root 'Start-KeystoneWeb.ps1')),'-LocalDev','-NoBrowser','-Port',[string]$port,'-WorkRoot',('"{0}"' -f (Join-Path $temp 'work')))
$startArgs = @{ FilePath = $exe; ArgumentList = $psArgs; PassThru = $true; RedirectStandardOutput = $out; RedirectStandardError = (Join-Path $temp 'host.err') }
if ($env:OS -eq 'Windows_NT') { $startArgs.WindowStyle = 'Hidden' }
$process = Start-Process @startArgs
try {
    $launch = $null
    for ($i = 0; $i -lt 120 -and -not $launch; $i++) {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) { throw "Keystone host exited early: $([IO.File]::ReadAllText($out))" }
        if (Test-Path -LiteralPath $out) {
            $m = [regex]::Match([IO.File]::ReadAllText($out),'Open: (http://127\.0\.0\.1:(\d+)/#k=([A-Za-z0-9_-]+))')
            if ($m.Success) { $launch = $m }
        }
    }
    Assert ([bool]$launch) 'Host never printed its launch link.'
    $base = "http://127.0.0.1:$($launch.Groups[2].Value)"
    $nonce = $launch.Groups[3].Value
    $page = Invoke-WebRequest -Uri ($base + '/') -UseBasicParsing -TimeoutSec 5
    Assert ($page.StatusCode -eq 200) 'UI not served.'
    Assert ([string]$page.Headers['Content-Security-Policy'] -notmatch 'unsafe-inline') 'CSP must not allow inline code.'

    $refused = $false
    try { Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Keystone-Client' = 'keystone-ui/1' } -TimeoutSec 5 | Out-Null }
    catch { $refused = ([int]$_.Exception.Response.StatusCode -eq 401) }
    Assert $refused 'API without a session must be refused.'

    $web = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $r = Invoke-WebRequest -Uri ($base + '/api/session') -Method Post -ContentType 'application/json' -Body ('{"nonce":"' + $nonce + '"}') -WebSession $web -UseBasicParsing -TimeoutSec 5
    Assert ($r.StatusCode -eq 200) 'Launch nonce exchange failed.'
    Assert ([string]$r.Headers['Set-Cookie'] -match 'HttpOnly; SameSite=Strict') 'Session cookie flags missing.'
    $status = Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Keystone-Client' = 'keystone-ui/1' } -WebSession $web -TimeoutSec 5
    Assert ($status.localDev -eq $true -and $status.connected -eq $false) 'Fresh LocalDev status wrong.'
    $integration = Invoke-RestMethod -Uri ($base + '/api/integrations') -Headers @{ 'X-Keystone-Client' = 'keystone-ui/1' } -WebSession $web -TimeoutSec 5
    Assert (@($integration.credentials).Count -eq 3) 'Credential status missing providers.'
    Assert (-not $integration.arc.enabled) 'ARC must be off unless configured.'

    $replay = $false
    try { Invoke-WebRequest -Uri ($base + '/api/session') -Method Post -ContentType 'application/json' -Body ('{"nonce":"' + $nonce + '"}') -UseBasicParsing -TimeoutSec 5 | Out-Null }
    catch { $replay = ([int]$_.Exception.Response.StatusCode -eq 401) }
    Assert $replay 'Launch nonce must work only once.'

    $badOrigin = $false
    try { Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Keystone-Client' = 'keystone-ui/1'; Origin = 'http://evil.example' } -WebSession $web -TimeoutSec 5 | Out-Null }
    catch { $badOrigin = ([int]$_.Exception.Response.StatusCode -eq 400) }
    Assert $badOrigin 'Foreign Origin must be refused.'
    Write-Host 'TcpListener host, launch link, session cookie and request gate passed.' -ForegroundColor Green
} finally {
    if ($process -and -not $process.HasExited) {
        if ($env:OS -eq 'Windows_NT') { try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch { } }
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
