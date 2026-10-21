#Requires -Version 5.1
<#
.SYNOPSIS
  Keystone local browser workspace. Windows PowerShell 5.1, no git.exe or Node required.
.DESCRIPTION
  Binds only to localhost, requires per-process CSRF token on writes, and never
  exposes Git/AI tokens through the browser. Ctrl+C stops the host.
#>
[CmdletBinding()]
param([ValidateRange(1025,65535)][int]$Port = 8769, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'Keystone.psm1') -Force
Initialize-Keystone
$session = $null
$buffer = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
$csrf = [Convert]::ToBase64String($buffer)
$nonce = [Convert]::ToBase64String($buffer).Replace('+','').Replace('/','').Replace('=','')
$listener = New-Object Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)

function Send-KeystoneWebJson {
    param($Response,[int]$Status = 200,$Value)
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes,0,$bytes.Length)
}
function Read-KeystoneWebBody {
    param($Request)
    if ($Request.ContentLength64 -lt 0 -or $Request.ContentLength64 -gt 131072) {
        throw 'Request must provide a Content-Length no greater than 128 KB.'
    }
    if ($Request.ContentType -notmatch '^application/json(?:\s*;|$)') { throw 'Expected application/json.' }
    $reader = New-Object IO.StreamReader($Request.InputStream,[Text.Encoding]::UTF8)
    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 131072) { throw 'Request is too large.' }
    if (-not $body) { throw 'Request body is empty.' }
    return ($body | ConvertFrom-Json)
}
function Test-KeystoneWebRequest {
    param($Request,[int]$Port,[string]$Csrf)
    if (-not [Net.IPAddress]::IsLoopback($Request.RemoteEndPoint.Address)) { return $false }
    if ($Request.Url.Host -ne 'localhost' -or $Request.Url.Port -ne $Port) { return $false }
    $origin = $Request.Headers['Origin']
    if ($origin -and $origin -ne "http://localhost:$Port") { return $false }
    if ($Request.HttpMethod -eq 'POST') {
        if ($Request.Headers['X-Keystone-Session'] -cne $Csrf) { return $false }
    }
    return $true
}

try {
    $listener.Start()
} catch {
    throw "Unable to start localhost listener on $prefix. Choose an unused port, or ask IT whether HttpListener requires a URL reservation. $($_.Exception.Message)"
}
Write-Host ''
Write-Host '  KEYSTONE  |  Enterprise Workspace' -ForegroundColor Cyan
Write-Host "  Browser: $prefix" -ForegroundColor Green
Write-Host '  Localhost only. Ctrl+C to stop. Repository secrets remain server-side.' -ForegroundColor DarkGray
if (-not $NoBrowser) {
    try { Start-Process $prefix | Out-Null }
    catch { Write-Host "Open this URL manually: $prefix" -ForegroundColor Yellow }
}
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req = $context.Request
        $res = $context.Response
        try {
            $res.Headers.Add('X-Content-Type-Options','nosniff')
            $res.Headers.Add('X-Frame-Options','DENY')
            $res.Headers.Add('Referrer-Policy','no-referrer')
            $res.Headers.Add('Cache-Control','no-store')
            $res.Headers.Add('Content-Security-Policy',"default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'")
            if (-not (Test-KeystoneWebRequest -Request $req -Port $Port -Csrf $csrf)) {
                Send-KeystoneWebJson -Response $res -Status 403 -Value @{ error = 'Request rejected by local session security policy.' }
                continue
            }
            $path = $req.Url.AbsolutePath
            if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
                $html = [IO.File]::ReadAllText((Join-Path $root 'web\index.html'),[Text.Encoding]::UTF8)
                $html = $html.Replace('__KEYSTONE_CSRF__',$csrf).Replace('__KEYSTONE_NONCE__',$nonce)
                $bytes = [Text.Encoding]::UTF8.GetBytes($html)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes,0,$bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
                Send-KeystoneWebJson -Response $res -Value @{
                    connected = ($null -ne $session)
                    provider = $(if ($session) { $session.Provider } else { $null })
                    project = $(if ($session) { $session.ProjectPath } else { $null })
                    branch = $(if ($session) { $session.LastBranch } else { $null })
                    workspace = $(if ($session) { $session.LocalPath } else { $null })
                    ai = [bool]($env:KEYSTONE_AI_TOKEN -or $env:GENAI_TOKEN)
                    canReview = [bool]($session -and $session.LastSaveMessage -and -not $session.LastReviewUrl)
                }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/connect') {
                $body = Read-KeystoneWebBody -Request $req
                if (-not $body.url -or ([string]$body.url).Length -gt 500) { throw 'Enter a valid GitHub or GitLab project URL.' }
                $session = Open-KeystoneRepository -Url ([string]$body.url)
                Send-KeystoneWebJson -Response $res -Value @{
                    project = $session.ProjectPath; provider = $session.Provider
                    branch = $session.DefaultBranch; branches = @($session.Branches)
                }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/start') {
                if (-not $session) { throw 'Connect a project first.' }
                $newBranch = New-KeystoneWorkBranch -Session $session
                $folder = Get-KeystoneSafeWorkspacePath -Base (Join-Path $root 'work') -Project $session.ProjectPath -Branch $newBranch
                $downloaded = Invoke-KeystonePull -Session $session -Branch $newBranch -LocalPath $folder
                Send-KeystoneWebJson -Response $res -Value @{ folder = $downloaded; branch = $newBranch; sha = $session.BaselineSha }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/download') {
                if (-not $session) { throw 'Connect a project first.' }
                $body = Read-KeystoneWebBody -Request $req
                $branch = if ($body.branch) { [string]$body.branch } else { $session.DefaultBranch }
                if ($branch.Length -gt 200) { throw 'Branch name is too long.' }
                $folder = Get-KeystoneSafeWorkspacePath -Base (Join-Path $root 'work') -Project $session.ProjectPath -Branch $branch
                $path = Invoke-KeystonePull -Session $session -Branch $branch -LocalPath $folder
                Send-KeystoneWebJson -Response $res -Value @{ folder = $path; branch = $branch; sha = $session.BaselineSha }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/preview') {
                if (-not $session -or -not $session.BaselineSha) {
                    Send-KeystoneWebJson -Response $res -Value @{ ready = $false; changes = @(); remoteChanged = $false }
                } else {
                    $preview = Get-KeystoneWorkspacePreview -Session $session
                    Send-KeystoneWebJson -Response $res -Value @{
                        ready = $true; changes = @($preview.Changes); remoteChanged = $preview.RemoteChanged
                        branch = $preview.Branch; message = $preview.SmartMessage.Title
                        workspace = $preview.LocalPath
                    }
                }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/commit-message') {
                if (-not $session) { throw 'Connect a project first.' }
                $body = Read-KeystoneWebBody -Request $req
                $preview = Get-KeystoneWorkspacePreview -Session $session
                $selected = @([string[]]@($body.paths))
                $known = @($preview.Changes | Where-Object { -not $_.Blocked } | ForEach-Object Path)
                foreach ($p in $selected) { if ($p -cnotin $known) { throw 'Invalid selected file.' } }
                if ($selected.Count -eq 0) { throw 'Select changed files first.' }
                $diff = [pscustomobject]@{
                    New = @($preview.Changes | Where-Object { $_.Kind -eq 'New' -and $_.Path -cin $selected } | ForEach-Object Path)
                    Modified = @($preview.Changes | Where-Object { $_.Kind -eq 'Modified' -and $_.Path -cin $selected } | ForEach-Object Path)
                    Deleted = @($preview.Changes | Where-Object { $_.Kind -eq 'Deleted' -and $_.Path -cin $selected } | ForEach-Object Path)
                }
                $prompt = Get-KeystoneSmartSavePrompt -Diff $diff
                $answer = Invoke-KeystoneAI -Question $prompt -CommitTitle
                $draft = New-KeystoneSmartMessage -Added $diff.New -Modified $diff.Modified -Deleted $diff.Deleted -AiSuggestion $answer
                Send-KeystoneWebJson -Response $res -Value @{ title = $draft.Title; source = $draft.Source }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/save') {
                if (-not $session) { throw 'Connect a project first.' }
                $body = Read-KeystoneWebBody -Request $req
                $selected = [string[]]@($body.paths)
                $message = if ($body.message) { [string]$body.message } else { '' }
                $saved = Invoke-KeystoneWorkspaceSave -Session $session -SelectedPaths $selected -Message $message
                $session | Add-Member -MemberType NoteProperty -Name LastSaveMessage -Value $saved.Message -Force
                $session | Add-Member -MemberType NoteProperty -Name LastSavedFiles -Value $selected -Force
                Send-KeystoneWebJson -Response $res -Value $saved
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/review') {
                if (-not $session -or -not $session.LastBranch) { throw 'Start a work branch before requesting review.' }
                if ($session.LastBranch -eq $session.DefaultBranch) { throw 'Cannot review the default branch against itself.' }
                if (-not $session.LastSaveMessage) { throw 'Save your changes before requesting review.' }
                if ($session.LastReviewUrl) {
                    Send-KeystoneWebJson -Response $res -Value @{ url = $session.LastReviewUrl; title = 'Review already created' }
                    continue
                }
                # Safe generated descriptions; no manually written PR text needed.
                $title = 'Review: ' + [string]$session.LastSaveMessage
                $desc = 'Created with Keystone Smart Save.' + [char]10 + [char]10 + 'Files in most recent save:' + [char]10
                foreach ($p in @($session.LastSavedFiles)) { $desc += '- ' + $p + [char]10 }
                $review = New-KeystoneMergeRequest -Session $session -SourceBranch $session.LastBranch -TargetBranch $session.DefaultBranch -Title $title -Description $desc
                $reviewUrl = if ($review.html_url) { [string]$review.html_url } else { [string]$review.web_url }
                $session | Add-Member -MemberType NoteProperty -Name LastReviewUrl -Value $reviewUrl -Force
                Send-KeystoneWebJson -Response $res -Value @{ url = $reviewUrl; title = $title }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/chat/stream') {
                $body = Read-KeystoneWebBody -Request $req
                if ([string]::IsNullOrWhiteSpace([string]$body.message)) { throw 'Enter a message.' }
                $res.ContentType = 'text/event-stream; charset=utf-8'
                $res.SendChunked = $true
                Invoke-KeystoneAIStream -Question ([string]$body.message) -Session $session -Response $res
            }
            else {
                Send-KeystoneWebJson -Response $res -Status 404 -Value @{ error = 'Route not found.' }
            }
        } catch {
            $message = $_.Exception.Message
            Write-KeystoneLog -Level WARN -Message "Web request failed: $path : $message"
            try {
                if ($res.SendChunked) {
                    Send-KeystoneSseEvent -Response $res -Event 'error' -Data $message
                } else {
                    Send-KeystoneWebJson -Response $res -Status 400 -Value @{ error = $message }
                }
            } catch { }
        } finally {
            try { $res.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
