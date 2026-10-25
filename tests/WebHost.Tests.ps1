#Requires -Version 5.1
# Windows-only localhost smoke test. Does not use credentials or remote services.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert($value,[string]$message) { if (-not $value) { throw "FAIL: $message" } }

# ---- Lifecycle rule: the tab owns the server (simulated clock, no sleeping) ----
. (Join-Path $root 'Core\Lifecycle.ps1')
$t0 = [DateTime]::UtcNow
Reset-KeystonePresence -AutoStop $true
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddHours(1))) 'nothing ever connected: -NoBrowser and CI hosts keep running'
Register-KeystonePresence -TabId 'tabA' -Now $t0
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddSeconds(19))) 'within the 20 s heartbeat timeout'
Assert (Test-KeystoneBrowserGone -Now $t0.AddSeconds(20)) 'no heartbeat for 20 s: stop'
Register-KeystonePresence -TabId 'tabA' -Now $t0.AddSeconds(30)
Register-KeystonePresence -TabId 'tabA' -Leaving -Now $t0.AddSeconds(31)
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddSeconds(35))) 'inside the 5 s leaving grace: a reload may follow'
Assert (Test-KeystoneBrowserGone -Now $t0.AddSeconds(36)) 'tab closed and the grace passed'
# Reload: the old page says it is leaving, the new page (new tab id) beats inside the grace.
Register-KeystonePresence -TabId 'tabB' -Now $t0.AddSeconds(33)
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddSeconds(40))) 'reload: the new page keeps the host alive'
Assert (Test-KeystoneBrowserGone -Now $t0.AddSeconds(53)) 'reloaded page gone too'
# Two tabs: closing one does not stop the host.
Reset-KeystonePresence -AutoStop $true
Register-KeystonePresence -TabId 'one' -Now $t0
Register-KeystonePresence -TabId 'two' -Now $t0
Register-KeystonePresence -TabId 'one' -Leaving -Now $t0.AddSeconds(1)
Register-KeystonePresence -TabId 'two' -Now $t0.AddSeconds(5)
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddSeconds(10))) 'one of two tabs closed: keep running'
Assert ((Get-KeystonePresenceState -Now $t0.AddSeconds(10)).tabs -eq 1) 'one live tab reported'
Assert (Test-KeystoneBrowserGone -Now $t0.AddSeconds(25)) 'last tab gone: stop'
# A long request (save, download) queues heartbeats: wait for them after it finishes.
Reset-KeystonePresence -AutoStop $true
Register-KeystonePresence -TabId 'saver' -Now $t0
Register-KeystoneRequestFinished -Now $t0.AddSeconds(40)
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddSeconds(44))) 'just after a long request: queued heartbeats get a grace'
Assert (Test-KeystoneBrowserGone -Now $t0.AddSeconds(45)) 'no heartbeat after the long request either: stop'
# Off switch.
Reset-KeystonePresence -AutoStop $false
Register-KeystonePresence -TabId 'x' -Leaving -Now $t0
Assert (-not (Test-KeystoneBrowserGone -Now $t0.AddHours(1))) 'auto-stop off: never stops by itself'
$savedFlag = $env:KEYSTONE_AUTO_STOP
try {
    $env:KEYSTONE_AUTO_STOP = $null
    Assert (Test-KeystoneAutoStopEnabled) 'auto-stop is on by default'
    Assert (-not (Test-KeystoneAutoStopEnabled -Stay)) '-Stay turns auto-stop off'
    Assert (-not (Test-KeystoneAutoStopEnabled -Config ([pscustomobject]@{ AutoStop = $false }))) 'config AutoStop=false turns it off'
    $env:KEYSTONE_AUTO_STOP = '0'
    Assert (-not (Test-KeystoneAutoStopEnabled)) 'KEYSTONE_AUTO_STOP=0 turns it off'
    $env:KEYSTONE_AUTO_STOP = '1'
    Assert (Test-KeystoneAutoStopEnabled -Config ([pscustomobject]@{ AutoStop = $false })) 'KEYSTONE_AUTO_STOP=1 overrides the config file'
} finally { $env:KEYSTONE_AUTO_STOP = $savedFlag }
# Runtime files: stale ones (dead pid) are removed on sight.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('keystone-lifecycle-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'Logs') -Force | Out-Null
    $stale = Join-Path $scratch 'Logs\keystone-server-999999.json'
    [IO.File]::WriteAllText($stale, '{"pid":999999,"port":1,"url":"http://localhost:1/","startedAt":"2000-01-01T00:00:00Z"}')
    $mine = Write-KeystoneRuntimeFile -Root $scratch -Port 12345 -Url 'http://localhost:12345/'
    $info = [IO.File]::ReadAllText($mine) | ConvertFrom-Json
    Assert ($info.pid -eq $PID -and $info.port -eq 12345 -and $info.url -and $info.startedAt) 'runtime file has pid, port, url, startedAt'
    Assert (@($info.PSObject.Properties.Name).Count -eq 4) 'runtime file has nothing else (no session token)'
    $found = @(Get-KeystoneServerProcesses -Root $scratch -ThisCheckout)
    Assert ($found.Count -eq 0) 'own runtime file is not reported as another instance'
    Assert (-not (Test-Path -LiteralPath $stale)) 'stale runtime file removed'
    Assert (Test-Path -LiteralPath $mine) 'own runtime file kept'
    Remove-KeystoneRuntimeFile -Path $mine
    Assert (-not (Test-Path -LiteralPath $mine)) 'runtime file removed on stop'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Browser presence rule, auto-stop switch and runtime files passed.' -ForegroundColor Green

# A host left over from an earlier run in this folder would hold the port and DLLs.
& (Join-Path $root 'Stop-Keystone.ps1') -ThisFolderOnly
$port = Get-Random -Minimum 19000 -Maximum 29000
$url = "http://localhost:$port/"
# Test the same BAT entrypoint users double-click, not just the PS1 host.
$launcher = Join-Path $root 'Launch-Keystone.bat'
$batchText = [IO.File]::ReadAllText($launcher)
if ($batchText -notmatch '(?i)-ExecutionPolicy\s+Bypass') { throw 'Keystone launcher is missing the process-scoped execution-policy option used by ARC/Cascade.' }
if ($batchText -notmatch '(?i)-STA') { throw 'Keystone launcher is missing the STA option needed for ARC UI compatibility.' }
$args = ('/d /c ""{0}" -NoBrowser {1}"' -f $launcher,$port)
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
$second = $null
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

    # ---- Lifecycle: runtime file, heartbeat auth, auto-stop, one instance, Stop-Keystone ----
    $runtime = @(Get-ChildItem -LiteralPath (Join-Path $root 'Logs') -Filter 'keystone-server-*.json' -ErrorAction SilentlyContinue |
        Where-Object { ([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).port -eq $port })
    Assert ($runtime.Count -eq 1) 'host wrote one runtime file for its port'
    $runtimeText = [IO.File]::ReadAllText($runtime[0].FullName)
    Assert ($runtimeText.IndexOf($csrf) -lt 0) 'runtime file must not contain the session token'
    $hostPid = [int]($runtimeText | ConvertFrom-Json).pid
    Assert ($status.autoStop -eq $true) 'auto-stop is on by default'
    $worker = Invoke-WebRequest -Uri ($url + 'heartbeat-worker.js') -UseBasicParsing -TimeoutSec 3
    Assert ($worker.Content -match '/api/heartbeat') 'heartbeat worker is served'
    $beat = Invoke-RestMethod -Method Post -Uri ($url + 'api/heartbeat') -Headers @{ 'X-Keystone-Session' = $csrf } -ContentType 'application/json' -Body '{"tab":"test1","leaving":false}' -TimeoutSec 3
    Assert ($beat.autoStop -eq $true -and $beat.tabs -eq 1) 'heartbeat with the session header is accepted'
    foreach ($bad in @('{"tab":"test1","leaving":true}', '{"tab":"test1","leaving":true,"session":"wrong"}')) {
        $code = 0
        try { Invoke-RestMethod -Method Post -Uri ($url + 'api/heartbeat') -ContentType 'application/json' -Body $bad -TimeoutSec 3 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
        Assert ($code -eq 403) ('heartbeat without a valid token must be rejected: ' + $bad)
    }
    $code = 0
    try { Invoke-RestMethod -Method Post -Uri ($url + 'api/heartbeat') -Headers @{ Origin = 'http://evil.invalid' } -ContentType 'application/json' -Body ('{"leaving":true,"session":"' + $csrf + '"}') -TimeoutSec 3 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 403) 'another site cannot send the leaving signal'
    $code = 0
    try { Invoke-RestMethod -Method Post -Uri ($url + 'api/connect') -ContentType 'application/json' -Body ('{"url":"https://github.com/a/b","session":"' + $csrf + '"}') -TimeoutSec 3 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 403) 'the body token is accepted on the heartbeat route only'
    $code = 0
    try { Invoke-RestMethod -Method Post -Uri ($url + 'api/session/stop') -Headers @{ 'X-Keystone-Session' = $csrf } -ContentType 'application/json' -Body '{}' -TimeoutSec 3 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 400) 'End session needs its intent header'

    # One instance: a second launch with --replace stops the first one and starts fresh.
    $port2 = $port + 1
    $url2 = "http://localhost:$port2/"
    $args2 = ('/d /c ""{0}" -NoBrowser {1} --replace"' -f $launcher,$port2)
    $second = Start-Process -FilePath 'cmd.exe' -ArgumentList $args2 -PassThru -WindowStyle Hidden
    $up = $null
    for ($attempt = 0; $attempt -lt 120 -and -not $up; $attempt++) {
        Start-Sleep -Milliseconds 250
        try { $up = Invoke-WebRequest -Uri $url2 -UseBasicParsing -TimeoutSec 2 } catch { if ($second.HasExited) { throw "Second Keystone exited unexpectedly: $($second.ExitCode)" } }
    }
    Assert $up 'second launch with --replace started'
    Assert (-not (Get-Process -Id $hostPid -ErrorAction SilentlyContinue)) '--replace stopped the first host'
    Assert (-not (Test-Path -LiteralPath $runtime[0].FullName)) 'first host runtime file removed'
    if ($up.Content -notmatch "const CSRF='([^']+)'") { throw 'Second host page has no CSRF bootstrap.' }
    $csrf2 = $Matches[1]

    # Tab owns the server: the unload beacon (token in the body, no header) stops it after the 5 s grace.
    $leaving = Invoke-RestMethod -Method Post -Uri ($url2 + 'api/heartbeat') -ContentType 'application/json' -Body ('{"tab":"closing","leaving":true,"session":"' + $csrf2 + '"}') -TimeoutSec 3
    Assert ($leaving.tabs -eq 0) 'beacon marked the only tab as leaving'
    $gone = $false
    for ($attempt = 0; $attempt -lt 60 -and -not $gone; $attempt++) {
        Start-Sleep -Milliseconds 250
        try { Invoke-WebRequest -Uri $url2 -UseBasicParsing -TimeoutSec 1 | Out-Null } catch { $gone = $true }
    }
    Assert $gone 'host stopped itself after its tab left'
    $left = @(Get-ChildItem -LiteralPath (Join-Path $root 'Logs') -Filter 'keystone-server-*.json' -ErrorAction SilentlyContinue |
        Where-Object { ([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).port -eq $port2 })
    for ($attempt = 0; $attempt -lt 20 -and $left.Count -gt 0; $attempt++) {
        Start-Sleep -Milliseconds 250
        $left = @($left | Where-Object { Test-Path -LiteralPath $_.FullName })
    }
    Assert ($left.Count -eq 0) 'auto-stopped host removed its runtime file'

    # Stop-Keystone.ps1 finds a host without being told its PID.
    $third = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /c ""{0}" -NoBrowser {1} --replace"' -f $launcher,$port) -PassThru -WindowStyle Hidden
    $second = $third
    $up = $null
    for ($attempt = 0; $attempt -lt 120 -and -not $up; $attempt++) {
        Start-Sleep -Milliseconds 250
        try { $up = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 } catch { if ($third.HasExited) { throw "Third Keystone exited unexpectedly: $($third.ExitCode)" } }
    }
    Assert $up 'third launch started'
    & (Join-Path $root 'Stop-Keystone.ps1') -ThisFolderOnly
    $stillUp = $true
    try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 1 | Out-Null } catch { $stillUp = $false }
    Assert (-not $stillUp) 'Stop-Keystone.ps1 stopped the host'
    Assert (@(Get-KeystoneServerProcesses -Root $root -ThisCheckout).Count -eq 0) 'no Keystone host left running from this folder'
    Write-Host 'Lifecycle: runtime file, heartbeat auth, auto-stop, --replace and Stop-Keystone passed.' -ForegroundColor Green
} finally {
    foreach ($p in @($process, $second)) {
        if ($p -and -not $p.HasExited) {
            # Kill the cmd.exe launcher and its child PowerShell process to avoid orphan servers.
            & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null
            if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
    }
    & (Join-Path $root 'Stop-Keystone.ps1') -ThisFolderOnly -Quiet
}
