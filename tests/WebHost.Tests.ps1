#Requires -Version 5.1
# Localhost smoke test of the real host under Windows PowerShell 5.1 (pwsh elsewhere).
# LocalDev, no credentials, no remote services. The full flow against a synthetic
# GitHub is tests/e2e/host.e2e.mjs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

# The BAT entrypoint users double-click must keep its PowerShell switches.
$batchText = [IO.File]::ReadAllText((Join-Path $root 'Launch-Gangplank.bat'))
$stubText = [IO.File]::ReadAllText((Join-Path $root 'Launch-Keystone.bat'))
Assert ($stubText -match '(?i)call "%~dp0Launch-Gangplank\.bat" %\*') 'Launch-Keystone.bat must forward to Launch-Gangplank.bat with all options'
Assert ([IO.File]::ReadAllText((Join-Path $root 'Stop-Keystone.ps1')) -match 'Stop-Gangplank\.ps1') 'Stop-Keystone.ps1 must forward to Stop-Gangplank.ps1'
Assert ($batchText -match '(?i)-ExecutionPolicy\s+Bypass') 'Gangplank launcher is missing the process-scoped execution-policy option used by Lazarette/Halyard.'
Assert ($batchText -match '(?i)-STA') 'Gangplank launcher is missing the STA option.'
Assert ($batchText -notmatch '(?i)set "ARC_PATH=') 'The launcher must not auto-configure Lazarette.'

# ---- Lifecycle rule: the tab owns the server (simulated clock, no sleeping) ----
. (Join-Path $root 'Core\Lifecycle.ps1')
$t0 = [DateTime]::UtcNow
Reset-GangplankPresence -AutoStop $true
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddHours(1))) 'nothing ever connected: -NoBrowser and CI hosts keep running'
Register-GangplankPresence -TabId 'tabA' -Now $t0
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddSeconds(19))) 'within the 20 s heartbeat timeout'
Assert (Test-GangplankBrowserGone -Now $t0.AddSeconds(20)) 'no heartbeat for 20 s: stop'
Register-GangplankPresence -TabId 'tabA' -Now $t0.AddSeconds(30)
Register-GangplankPresence -TabId 'tabA' -Leaving -Now $t0.AddSeconds(31)
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddSeconds(35))) 'inside the 5 s leaving grace: a reload may follow'
Assert (Test-GangplankBrowserGone -Now $t0.AddSeconds(36)) 'tab closed and the grace passed'
# Reload: the old page says it is leaving, the new page (new tab id) beats inside the grace.
Register-GangplankPresence -TabId 'tabB' -Now $t0.AddSeconds(33)
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddSeconds(40))) 'reload: the new page keeps the host alive'
Assert (Test-GangplankBrowserGone -Now $t0.AddSeconds(53)) 'reloaded page gone too'
# Two tabs: closing one does not stop the host.
Reset-GangplankPresence -AutoStop $true
Register-GangplankPresence -TabId 'one' -Now $t0
Register-GangplankPresence -TabId 'two' -Now $t0
Register-GangplankPresence -TabId 'one' -Leaving -Now $t0.AddSeconds(1)
Register-GangplankPresence -TabId 'two' -Now $t0.AddSeconds(5)
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddSeconds(10))) 'one of two tabs closed: keep running'
Assert ((Get-GangplankPresenceState -Now $t0.AddSeconds(10)).tabs -eq 1) 'one live tab reported'
Assert (Test-GangplankBrowserGone -Now $t0.AddSeconds(25)) 'last tab gone: stop'
# A long request (save, download) queues heartbeats: wait for them after it finishes.
Reset-GangplankPresence -AutoStop $true
Register-GangplankPresence -TabId 'saver' -Now $t0
Register-GangplankRequestFinished -Now $t0.AddSeconds(40)
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddSeconds(44))) 'just after a long request: queued heartbeats get a grace'
Assert (Test-GangplankBrowserGone -Now $t0.AddSeconds(45)) 'no heartbeat after the long request either: stop'
# Off switch.
Reset-GangplankPresence -AutoStop $false
Register-GangplankPresence -TabId 'x' -Leaving -Now $t0
Assert (-not (Test-GangplankBrowserGone -Now $t0.AddHours(1))) 'auto-stop off: never stops by itself'
$savedFlag = $env:GANGPLANK_AUTO_STOP
try {
    $env:GANGPLANK_AUTO_STOP = $null
    Assert (Test-GangplankAutoStopEnabled) 'auto-stop is on by default'
    Assert (-not (Test-GangplankAutoStopEnabled -Stay)) '-Stay turns auto-stop off'
    Assert (-not (Test-GangplankAutoStopEnabled -Config ([pscustomobject]@{ AutoStop = $false }))) 'config AutoStop=false turns it off'
    $env:GANGPLANK_AUTO_STOP = '0'
    Assert (-not (Test-GangplankAutoStopEnabled)) 'GANGPLANK_AUTO_STOP=0 turns it off'
    $env:GANGPLANK_AUTO_STOP = '1'
    Assert (Test-GangplankAutoStopEnabled -Config ([pscustomobject]@{ AutoStop = $false })) 'GANGPLANK_AUTO_STOP=1 overrides the config file'
} finally { $env:GANGPLANK_AUTO_STOP = $savedFlag }
# Runtime files: stale ones (dead pid) are removed on sight.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lifecycle-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'Logs') -Force | Out-Null
    $stale = Join-Path $scratch 'Logs\gangplank-server-999999.json'
    [IO.File]::WriteAllText($stale, '{"pid":999999,"port":1,"url":"http://localhost:1/","startedAt":"2000-01-01T00:00:00Z"}')
    $mine = Write-GangplankRuntimeFile -Root $scratch -Port 12345 -Url 'http://localhost:12345/' -StateRoot (Join-Path $scratch 'state')
    $info = [IO.File]::ReadAllText($mine) | ConvertFrom-Json
    Assert ($info.pid -eq $PID -and $info.port -eq 12345 -and $info.url -and $info.startedAt) 'runtime file has pid, port, url, startedAt'
    Assert (@($info.PSObject.Properties.Name).Count -eq 5 -and $info.PSObject.Properties['stateRoot']) 'runtime file has the saved-session folder and nothing else (no secrets)'
    $found = @(Get-GangplankServerProcesses -Root $scratch -ThisCheckout)
    Assert ($found.Count -eq 0) 'own runtime file is not reported as another instance'
    Assert (-not (Test-Path -LiteralPath $stale)) 'stale runtime file removed'
    Assert (Test-Path -LiteralPath $mine) 'own runtime file kept'
    Remove-GangplankRuntimeFile -Path $mine
    Assert (-not (Test-Path -LiteralPath $mine)) 'runtime file removed on stop'
    # Instances are told apart by their saved-session folder.
    Assert (Test-GangplankSameStateRoot (Join-Path $scratch 'a') (Join-Path $scratch 'A')) 'state folders compare case-insensitively'
    Assert (-not (Test-GangplankSameStateRoot (Join-Path $scratch 'a') (Join-Path $scratch 'b'))) 'different state folders are different sessions'
    Assert ((Get-GangplankCommandLineStateRoot -CommandLine 'powershell -File "C:\k\Start-Gangplank.ps1" -LocalDev -WorkRoot "C:\tmp\w x"') -eq [IO.Path]::Combine('C:\tmp\w x', '.gangplank')) 'quoted -WorkRoot parsed from a command line'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
# ---- Rename compatibility: Keystone data folder, runtime files and host names ----
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-rename-' + [Guid]::NewGuid().ToString('N'))
try {
    $old = Join-Path $scratch 'Keystone'; $new = Join-Path $scratch 'Gangplank'
    [void](New-Item -ItemType Directory -Path $old -Force)
    [IO.File]::WriteAllText((Join-Path $old 'session.json'), '{"Version":1}')
    Assert (Copy-GangplankLegacyStateFolder -From $old -To $new) 'Keystone data folder copied forward'
    Assert ([IO.File]::ReadAllText((Join-Path $new 'session.json')) -eq '{"Version":1}') 'saved session copied'
    Assert (Test-Path -LiteralPath (Join-Path $old 'session.json')) 'the Keystone folder is left untouched'
    [IO.File]::WriteAllText((Join-Path $new 'session.json'), '{"Version":2}')
    Assert (-not (Copy-GangplankLegacyStateFolder -From $old -To $new)) 'copy-forward runs once (new folder exists)'
    Assert ([IO.File]::ReadAllText((Join-Path $new 'session.json')) -eq '{"Version":2}') 'a later run never overwrites Gangplank data'
    Assert (-not (Copy-GangplankLegacyStateFolder -From (Join-Path $scratch 'none') -To (Join-Path $scratch 'x'))) 'nothing to copy is fine'
    Assert (@(Get-ChildItem -LiteralPath $scratch -Force | Where-Object { $_.Name -like '.*-migrating-*' }).Count -eq 0) 'no temporary folder left behind'
    # A Keystone-era host shares the session it was copied from.
    Assert (Test-GangplankSameStateRoot (Join-Path $scratch 'Keystone') (Join-Path $scratch 'Gangplank')) '%LOCALAPPDATA%\Keystone and \Gangplank are the same session'
    Assert (Test-GangplankSameStateRoot (Join-Path $scratch '.keystone') (Join-Path $scratch '.gangplank')) '<WorkRoot>\.keystone and \.gangplank are the same session'
    Assert ((Get-GangplankCommandLineStateRoot -CommandLine 'powershell -File "C:\k\Start-KeystoneWeb.ps1" -WorkRoot "C:\w"') -eq [IO.Path]::Combine('C:\w', '.keystone')) 'Keystone host command line recognised'
    Assert ((Get-GangplankStopEventName -ProcessId 7 -Legacy) -eq 'Local\Keystone-Stop-7') 'Keystone stop event name kept for older hosts'
    # A stale Keystone runtime file is cleaned up like a Gangplank one.
    [void](New-Item -ItemType Directory -Path (Join-Path $scratch 'Logs') -Force)
    $staleOld = Join-Path $scratch 'Logs\keystone-server-999998.json'
    [IO.File]::WriteAllText($staleOld, '{"pid":999998,"port":1,"url":"http://localhost:1/","startedAt":"2000-01-01T00:00:00Z"}')
    [void](Get-GangplankServerProcesses -Root $scratch -ThisCheckout)
    Assert (-not (Test-Path -LiteralPath $staleOld)) 'stale Keystone runtime file removed'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Browser presence rule, auto-stop switch and runtime files passed.' -ForegroundColor Green

$port = Get-Random -Minimum 19000 -Maximum 29000
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-webhost-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
$out = Join-Path $temp 'host.out'
$exe = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { 'powershell.exe' }
# Explicit LocalDev so an unattended runner never imports Lazarette or waits on an unlock prompt.
$psArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $root 'Start-Gangplank.ps1')),'-LocalDev','-NoBrowser','-Port',[string]$port,'-WorkRoot',('"{0}"' -f (Join-Path $temp 'work')))
$second = $null; $third = $null; $fourth = $null
$startArgs = @{ FilePath = $exe; ArgumentList = $psArgs; PassThru = $true; RedirectStandardOutput = $out; RedirectStandardError = (Join-Path $temp 'host.err') }
if ($env:OS -eq 'Windows_NT') { $startArgs.WindowStyle = 'Hidden' }
# The host is a separate process: give it a throwaway LOCALAPPDATA so it never sees
# the real credential store or saved session of the account running the test.
$savedAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $temp 'appdata'
try { $process = Start-Process @startArgs } finally { $env:LOCALAPPDATA = $savedAppData }
try {
    $launch = $null
    for ($i = 0; $i -lt 120 -and -not $launch; $i++) {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) { throw "Gangplank host exited early (exit $($process.ExitCode)). See $out." }
        if (Test-Path -LiteralPath $out) {
            # The host still has this file open for writing: read with shared access.
            $fs = [IO.File]::Open($out,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
            $m = [regex]::Match($text,'Open: (http://127\.0\.0\.1:(\d+)/#k=([A-Za-z0-9_-]+))')
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
    try { Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Gangplank-Client' = 'gangplank-ui/1' } -TimeoutSec 5 | Out-Null }
    catch { $refused = ([int]$_.Exception.Response.StatusCode -eq 401) }
    Assert $refused 'API without a session must be refused.'

    $web = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $r = Invoke-WebRequest -Uri ($base + '/api/session') -Method Post -ContentType 'application/json' -Body ('{"nonce":"' + $nonce + '"}') -WebSession $web -UseBasicParsing -TimeoutSec 5
    Assert ($r.StatusCode -eq 200) 'Launch nonce exchange failed.'
    Assert ([string]$r.Headers['Set-Cookie'] -match 'HttpOnly; SameSite=Strict') 'Session cookie flags missing.'
    $client = [string](($r.Content | ConvertFrom-Json).client)
    Assert ($client.Length -ge 40) 'Session must return a per-session client secret.'
    $guessed = $false
    try { Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Gangplank-Client' = 'gangplank-ui/1' } -WebSession $web -TimeoutSec 5 | Out-Null }
    catch { $guessed = ([int]$_.Exception.Response.StatusCode -eq 401) }
    Assert $guessed 'A replayed cookie without the client secret must be refused.'
    $status = Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Gangplank-Client' = $client } -WebSession $web -TimeoutSec 5
    Assert ($status.localDev -eq $true -and $status.connected -eq $false) 'Fresh LocalDev status wrong.'
    $integration = Invoke-RestMethod -Uri ($base + '/api/integrations') -Headers @{ 'X-Gangplank-Client' = $client } -WebSession $web -TimeoutSec 5
    Assert (@($integration.credentials).Count -eq 3) 'Credential status missing providers.'
    Assert (-not $integration.arc.enabled) 'Lazarette must be off unless configured.'

    $replay = $false
    try { Invoke-WebRequest -Uri ($base + '/api/session') -Method Post -ContentType 'application/json' -Body ('{"nonce":"' + $nonce + '"}') -UseBasicParsing -TimeoutSec 5 | Out-Null }
    catch { $replay = ([int]$_.Exception.Response.StatusCode -eq 401) }
    Assert $replay 'Launch nonce must work only once.'

    $badOrigin = $false
    try { Invoke-RestMethod -Uri ($base + '/api/status') -Headers @{ 'X-Gangplank-Client' = $client; Origin = 'http://evil.example' } -WebSession $web -TimeoutSec 5 | Out-Null }
    catch { $badOrigin = ([int]$_.Exception.Response.StatusCode -eq 400) }
    Assert $badOrigin 'Foreign Origin must be refused.'
    Write-Host 'TcpListener host, launch link, session cookie and request gate passed.' -ForegroundColor Green

    # ---- Lifecycle on the live host: runtime file, heartbeat auth, End session gate ----
    # Invoke-* keeps -Headers in the -WebSession (the evil Origin above, the client header):
    # start clean so each call below sends exactly what it states.
    $web.Headers.Clear()
    Assert ($status.autoStop -eq $true) 'auto-stop is on by default'
    $runtime = @(Get-ChildItem -LiteralPath (Join-Path $root 'Logs') -Filter 'gangplank-server-*.json' -ErrorAction SilentlyContinue |
        Where-Object { ([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).pid -eq $process.Id })
    Assert ($runtime.Count -eq 1) 'host wrote one runtime file'
    $runtimeText = [IO.File]::ReadAllText($runtime[0].FullName)
    Assert ($runtimeText.IndexOf($client) -lt 0 -and $runtimeText.IndexOf($nonce) -lt 0) 'runtime file must not contain the launch link or client secret'
    Assert ((Test-GangplankSameStateRoot ([string]($runtimeText | ConvertFrom-Json).stateRoot) (Join-Path (Join-Path $temp 'work') '.gangplank'))) 'runtime file names the saved-session folder'
    $worker = Invoke-WebRequest -Uri ($base + '/heartbeat-worker.js') -UseBasicParsing -TimeoutSec 5
    Assert ($worker.Content -match '/api/heartbeat') 'heartbeat worker is served'
    Assert ([string]$page.Headers['Content-Security-Policy'] -match "worker-src 'self'") 'CSP allows the same-origin heartbeat worker'
    $beat = Invoke-RestMethod -Method Post -Uri ($base + '/api/heartbeat') -Headers @{ 'X-Gangplank-Client' = $client } -WebSession $web -ContentType 'application/json' -Body '{"tab":"test1","leaving":false}' -TimeoutSec 5
    Assert ($beat.autoStop -eq $true -and $beat.tabs -eq 1) 'heartbeat with the session is accepted'
    $code = 0
    try { Invoke-RestMethod -Method Post -Uri ($base + '/api/heartbeat') -ContentType 'application/json' -Body ('{"tab":"x","leaving":true,"client":"' + $client + '"}') -TimeoutSec 5 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 401) 'beacon without the session cookie must be refused'
    $code = 0
    $web.Headers.Clear()
    try { Invoke-RestMethod -Method Post -Uri ($base + '/api/heartbeat') -WebSession $web -ContentType 'application/json' -Body '{"tab":"x","leaving":true,"client":"wrong"}' -TimeoutSec 5 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 401) 'beacon with a wrong client secret must be refused'
    $code = 0
    $web.Headers.Clear()
    try { Invoke-RestMethod -Method Post -Uri ($base + '/api/status') -WebSession $web -ContentType 'application/json' -Body ('{"client":"' + $client + '"}') -TimeoutSec 5 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 401) 'the body secret is accepted on the heartbeat route only'
    $code = 0
    $web.Headers.Clear()
    try { Invoke-RestMethod -Method Post -Uri ($base + '/api/session/stop') -Headers @{ 'X-Gangplank-Client' = $client } -WebSession $web -ContentType 'application/json' -Body '{}' -TimeoutSec 5 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 400) 'End session needs its intent header'

    # Tab owns the server: the unload beacon (secret in the body, cookie sent) stops it after the 5 s grace.
    $web.Headers.Clear()
    $leaving = Invoke-RestMethod -Method Post -Uri ($base + '/api/heartbeat') -WebSession $web -ContentType 'application/json' -Body ('{"tab":"test1","leaving":true,"client":"' + $client + '"}') -TimeoutSec 5
    Assert ($leaving.tabs -eq 0) 'beacon marked the only tab as leaving'
    for ($i = 0; $i -lt 80 -and -not $process.HasExited; $i++) { Start-Sleep -Milliseconds 250 }
    Assert $process.HasExited 'host stopped itself after its tab left'
    Assert (-not (Test-Path -LiteralPath $runtime[0].FullName)) 'auto-stopped host removed its runtime file'
    Write-Host 'Lifecycle: runtime file, heartbeat auth and auto-stop passed.' -ForegroundColor Green

    # ---- One instance (--replace), End session and Stop-Gangplank.ps1, through the launcher options ----
    $hostScript = Join-Path $root 'Start-Gangplank.ps1'
    function Start-TestHost([string[]]$Extra,[string]$Out) {
        $a = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $hostScript),'-LocalDev','-NoBrowser','-WorkRoot',('"{0}"' -f (Join-Path $temp 'work'))) + $Extra
        $sa = @{ FilePath = $exe; ArgumentList = $a; PassThru = $true; RedirectStandardOutput = $Out; RedirectStandardError = ($Out + '.err') }
        if ($env:OS -eq 'Windows_NT') { $sa.WindowStyle = 'Hidden' }
        $saved = $env:LOCALAPPDATA; $env:LOCALAPPDATA = Join-Path $temp 'appdata'
        try { return (Start-Process @sa) } finally { $env:LOCALAPPDATA = $saved }
    }
    function Wait-TestLink($Proc,[string]$Out) {
        for ($i = 0; $i -lt 160; $i++) {
            Start-Sleep -Milliseconds 250
            if ($Proc.HasExited) { throw "Gangplank host exited early (exit $($Proc.ExitCode)). See $Out." }
            if (Test-Path -LiteralPath $Out) {
                $fs = [IO.File]::Open($Out,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                try { $t = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
                $m = [regex]::Match($t,'Open: (http://127\.0\.0\.1:(\d+)/#k=([A-Za-z0-9_-]+))')
                if ($m.Success) { return $m }
            }
        }
        throw 'Host never printed its launch link.'
    }
    $out2 = Join-Path $temp 'host2.out'
    $second = Start-TestHost -Extra @([string]$port) -Out $out2
    [void](Wait-TestLink $second $out2)
    $out3 = Join-Path $temp 'host3.out'
    $third = Start-TestHost -Extra @([string]($port + 1),'--replace') -Out $out3
    $link3 = Wait-TestLink $third $out3
    for ($i = 0; $i -lt 40 -and -not $second.HasExited; $i++) { Start-Sleep -Milliseconds 250 }
    Assert $second.HasExited '--replace stopped the host using the same saved session'
    # End session through the API.
    $base3 = "http://127.0.0.1:$($link3.Groups[2].Value)"
    $web3 = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $r3 = Invoke-WebRequest -Uri ($base3 + '/api/session') -Method Post -ContentType 'application/json' -Body ('{"nonce":"' + $link3.Groups[3].Value + '"}') -WebSession $web3 -UseBasicParsing -TimeoutSec 5
    $client3 = [string](($r3.Content | ConvertFrom-Json).client)
    $stop = Invoke-RestMethod -Method Post -Uri ($base3 + '/api/session/stop') -Headers @{ 'X-Gangplank-Client' = $client3; 'X-Gangplank-Intent' = 'end-session' } -WebSession $web3 -ContentType 'application/json' -Body '{}' -TimeoutSec 5
    Assert ($stop.stopping -eq $true) 'End session accepted'
    for ($i = 0; $i -lt 40 -and -not $third.HasExited; $i++) { Start-Sleep -Milliseconds 250 }
    Assert $third.HasExited 'End session stopped the host'
    # Stop-Gangplank.ps1 finds a host without its PID (scoped to this test's -WorkRoot).
    $out4 = Join-Path $temp 'host4.out'
    $fourth = Start-TestHost -Extra @([string]$port,'--stay') -Out $out4
    [void](Wait-TestLink $fourth $out4)
    & (Join-Path $root 'Stop-Gangplank.ps1') -WorkRoot (Join-Path $temp 'work')
    for ($i = 0; $i -lt 40 -and -not $fourth.HasExited; $i++) { Start-Sleep -Milliseconds 250 }
    Assert $fourth.HasExited 'Stop-Gangplank.ps1 stopped the host'
    Assert (@(Get-GangplankServerProcesses -Root $root -StateRoot (Join-Path (Join-Path $temp 'work') '.gangplank')).Count -eq 0) 'no test host left running'
    Write-Host 'Lifecycle: --replace, End session and Stop-Gangplank passed.' -ForegroundColor Green
} finally {
    foreach ($p in @($second,$third,$fourth)) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    if ($process -and -not $process.HasExited) {
        if ($env:OS -eq 'Windows_NT') { try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch { } }
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
