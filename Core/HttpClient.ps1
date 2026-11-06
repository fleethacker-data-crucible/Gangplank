#Requires -Version 5.1
# ============================================================
#  Core/HttpClient.ps1 - one HTTP transport for every provider call
#  - HttpWebRequest with redirects OFF: a token is never sent to a host it was
#    not meant for. Callers follow redirects themselves (archive downloads).
#  - Bounded retry for GET/HEAD only, on 429/502/503/504 and network errors,
#    honouring Retry-After (capped). Writes are never retried.
#  - Failures become coded errors: CODE|Provider API METHOD endpoint failed (HTTP n).
# ============================================================

$script:GangplankHttpTransport = $null    # test seam: { param($Request) ... returns response }
$script:GangplankHttpSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
$script:GangplankHttpMaxRetryWaitMs = 10000
# Set by the HTTP loop while answering a request: one attempt, short timeout.
$script:GangplankHttpInteractive = $false

function Get-GangplankProviderErrorCode {
    param([int]$Status,[hashtable]$Headers = @{})
    if ($Status -eq 0) { return 'NETWORK' }
    if ($Status -eq 401) { return 'AUTH_REJECTED' }
    if ($Status -eq 403) {
        if ($Headers['x-ratelimit-remaining'] -eq '0') { return 'RATE_LIMITED' }
        return 'FORBIDDEN'
    }
    if ($Status -eq 404) { return 'NOT_FOUND' }
    if ($Status -eq 409 -or $Status -eq 422) { return 'CONFLICT' }
    if ($Status -eq 429) { return 'RATE_LIMITED' }
    if ($Status -ge 500) { return 'SERVER_ERROR' }
    return "HTTP_$Status"
}

function Get-GangplankGitHubRateLimitMessage {
    # Anonymous GitHub is 60 requests an hour (search is 10). A token is optional:
    # say so, and never claim public repositories require one. No header values
    # other than the numeric limit and reset time are included.
    param([hashtable]$Headers = @{})
    $limit = ''
    if ($Headers -and $Headers.ContainsKey('x-ratelimit-limit')) { $limit = [string]$Headers['x-ratelimit-limit'] }
    $resetText = ''
    $resetRaw = ''
    if ($Headers -and $Headers.ContainsKey('x-ratelimit-reset')) { $resetRaw = [string]$Headers['x-ratelimit-reset'] }
    $epoch = [int64]0
    if ($resetRaw -and [int64]::TryParse($resetRaw,[ref]$epoch) -and $epoch -gt 0) {
        $when = (New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds($epoch)
        $resetText = ' The limit resets at ' + $when.ToString('yyyy-MM-dd HH:mm') + ' UTC.'
    }
    if ($limit -eq '60' -or $limit -eq '10') {
        return ("GitHub's limit for requests without a token was reached ({0} per hour from this address). Public repositories do not require a token. Wait and try again, or add an optional token in Settings to raise the limit.{1}" -f $limit, $resetText)
    }
    return ("GitHub's rate limit was reached for this address. Public repositories do not require a token. Wait and try again, or add an optional token in Settings if you want a higher limit.{0}" -f $resetText)
}

function Get-GangplankRetryDelayMs {
    param([hashtable]$Headers,[int]$Attempt)
    $after = [string]$Headers['retry-after']
    $seconds = 0
    if ($after -and [int]::TryParse($after,[ref]$seconds)) { return [Math]::Min($seconds * 1000, $script:GangplankHttpMaxRetryWaitMs) }
    return [Math]::Min(500 * [Math]::Pow(2,$Attempt - 1), $script:GangplankHttpMaxRetryWaitMs)
}

function Invoke-GangplankHttpOnce {
    param([pscustomobject]$Request)
    if ($script:GangplankHttpTransport) { return (& $script:GangplankHttpTransport $Request) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [Net.HttpWebRequest]::Create($Request.Uri)
    $req.Method = $Request.Method
    $req.AllowAutoRedirect = $false
    $req.Timeout = $Request.TimeoutSec * 1000
    $req.ReadWriteTimeout = $Request.TimeoutSec * 1000
    $req.UserAgent = 'Gangplank'
    # .NET Framework sends "Expect: 100-continue" on POST by default; some proxies answer 417.
    try { $req.ServicePoint.Expect100Continue = $false } catch { }
    foreach ($k in $Request.Headers.Keys) {
        $v = [string]$Request.Headers[$k]
        switch ($k.ToLowerInvariant()) {
            'accept' { $req.Accept = $v }
            'content-type' { $req.ContentType = $v }
            'user-agent' { $req.UserAgent = $v }
            default { $req.Headers[$k] = $v }
        }
    }
    if ($null -ne $Request.Body) {
        $bytes = if ($Request.Body -is [byte[]]) { $Request.Body } else { [Text.Encoding]::UTF8.GetBytes([string]$Request.Body) }
        if (-not $req.ContentType) { $req.ContentType = 'application/json' }
        # Bodies are always UTF-8 bytes; say so, or servers may assume ISO-8859-1.
        if ($Request.Body -isnot [byte[]] -and $req.ContentType -notmatch 'charset=') { $req.ContentType = $req.ContentType + '; charset=utf-8' }
        $req.ContentLength = $bytes.Length
        try {
            $stream = $req.GetRequestStream()
            try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        } catch {
            # Could not even send (offline, DNS, proxy): a network failure, not a crash.
            $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
            return [pscustomobject]@{ Status = 0; Headers = @{}; Text = ''; File = $null; NetworkError = $inner.GetType().Name }
        }
    } elseif ($Request.Method -in @('POST','PUT','PATCH')) {
        $req.ContentLength = 0
    }
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) {
            return [pscustomobject]@{ Status = 0; Headers = @{}; Text = ''; File = $null; NetworkError = $_.Exception.Status.ToString() }
        }
    }
    try {
        $headers = @{}
        foreach ($name in $resp.Headers.AllKeys) { $headers[$name.ToLowerInvariant()] = $resp.Headers[$name] }
        $status = [int]$resp.StatusCode
        $text = ''
        $file = $null
        $body = $resp.GetResponseStream()
        try {
            if ($Request.OutFile -and $status -ge 200 -and $status -lt 300) {
                $out = [IO.File]::Open($Request.OutFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                try { $body.CopyTo($out) } finally { $out.Dispose() }
                $file = $Request.OutFile
            } else {
                $reader = New-Object IO.StreamReader($body,[Text.Encoding]::UTF8)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } finally { if ($body) { $body.Dispose() } }
        return [pscustomobject]@{ Status = $status; Headers = $headers; Text = $text; File = $file; NetworkError = '' }
    } finally { $resp.Dispose() }
}

function Invoke-GangplankHttpRequest {
    # Returns @{ Status; Headers; Text; File } for any HTTP status (callers decide),
    # or throws NETWORK after retries. 3xx responses are returned, not followed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        $Body = $null,
        [string]$OutFile,
        [int]$TimeoutSec = 60,
        [int]$MaxAttempts = 0
    )
    $idempotent = $Method -in @('GET','HEAD')
    if ($MaxAttempts -le 0) { $MaxAttempts = if ($idempotent) { 3 } else { 1 } }
    if (-not $idempotent) { $MaxAttempts = 1 }
    if ($script:GangplankHttpInteractive) { $MaxAttempts = 1; $TimeoutSec = [Math]::Min($TimeoutSec,20) }
    $request = [pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; OutFile = $OutFile; TimeoutSec = $TimeoutSec }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $response = Invoke-GangplankHttpOnce -Request $request
        # API reads follow redirects on the SAME host only (GitHub uses 301/307 for
        # renamed or transferred repositories). Other hosts never get the token.
        $hops = 0
        while ($idempotent -and -not $OutFile -and $hops -lt 3 -and $response.Status -in @(301,302,307,308) -and $response.Headers['location']) {
            $next = [uri]::new([uri]$request.Uri,[string]$response.Headers['location'])
            if ($next.Authority -ne ([uri]$request.Uri).Authority -or $next.Scheme -ne ([uri]$request.Uri).Scheme) { break }
            $request.Uri = $next.AbsoluteUri
            $response = Invoke-GangplankHttpOnce -Request $request
            $hops++
        }
        $retryable = ($response.Status -eq 0) -or ($response.Status -in @(429,502,503,504))
        if (-not $retryable -or $attempt -eq $MaxAttempts) { return $response }
        $wait = Get-GangplankRetryDelayMs -Headers $response.Headers -Attempt $attempt
        Write-GangplankLog -Level WARN -Message ("HTTP {0} {1} returned {2}; retry {3} in {4} ms" -f $Method, (Get-GangplankSafeUrl $Uri), $response.Status, $attempt, $wait)
        & $script:GangplankHttpSleep $wait
    }
}

function Get-GangplankSafeUrl {
    # Scheme, host and path only: query strings can carry signed tokens.
    param([string]$Uri)
    try { $u = [uri]$Uri; return ('{0}://{1}{2}' -f $u.Scheme, $u.Authority, $u.AbsolutePath) } catch { return '(invalid url)' }
}

function ConvertFrom-GangplankApiResponse {
    # Parse a JSON API response or throw a coded, body-free error.
    param([Parameter(Mandatory)][string]$Provider,[string]$Method,[string]$Endpoint,[Parameter(Mandatory)]$Response)
    $status = [int]$Response.Status
    if ($status -ge 200 -and $status -lt 300) {
        if ([string]::IsNullOrWhiteSpace($Response.Text)) { return $null }
        return ($Response.Text | ConvertFrom-Json)
    }
    $code = Get-GangplankProviderErrorCode -Status $status -Headers $Response.Headers
    $detail = [string]$Response.Text
    if ($detail.Length -gt 500) { $detail = $detail.Substring(0,500) + '...' }
    if ($status -eq 0) { $detail = $Response.NetworkError }
    Write-GangplankLog -Level ERROR -Message ("{0} API fail {1} {2} status={3} {4}" -f $Provider, $Method, $Endpoint, $status, $detail)
    if ($Provider -eq 'GitHub' -and $code -eq 'RATE_LIMITED') {
        throw ("RATE_LIMITED|" + (Get-GangplankGitHubRateLimitMessage -Headers $Response.Headers))
    }
    $statusText = if ($status) { [string]$status } else { 'no response' }
    throw ("{0}|{1} API {2} {3} failed (HTTP {4})." -f $code, $Provider, $Method, $Endpoint, $statusText)
}

function Invoke-GangplankDownload {
    # Download to a new file, following up to 3 redirects. The auth headers go
    # only to the original host; a redirect to another host (GitHub codeload,
    # object storage) is fetched without them, as those URLs are pre-signed.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$Uri,[hashtable]$AuthHeaders = @{},[Parameter(Mandatory)][string]$OutFile,[int]$TimeoutSec = 300)
    $origin = ([uri]$Uri).Authority
    $current = $Uri
    for ($hop = 0; $hop -le 3; $hop++) {
        $sameHost = (([uri]$current).Authority -eq $origin)
        $headers = if ($sameHost) { $AuthHeaders } else { @{ 'User-Agent' = 'Gangplank' } }
        if (([uri]$current).Scheme -ne ([uri]$Uri).Scheme -and ([uri]$current).Scheme -ne 'https') { throw "NETWORK|$Provider download redirected to an insecure address." }
        $r = Invoke-GangplankHttpRequest -Method GET -Uri $current -Headers $headers -OutFile $OutFile -TimeoutSec $TimeoutSec
        if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Headers['location']) {
            $current = ([uri]::new([uri]$current, [string]$r.Headers['location'])).AbsoluteUri
            continue
        }
        if ($r.File) { return $r.File }
        [void](ConvertFrom-GangplankApiResponse -Provider $Provider -Method GET -Endpoint (Get-GangplankSafeUrl $current) -Response $r)
        throw "NETWORK|$Provider download returned no content."
    }
    throw "NETWORK|$Provider download redirected too many times."
}

function Set-GangplankPageQuery {
    # The same URI with its page parameter set to $Page (other query values kept).
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string]$Page)
    $u = [uri]$Uri
    $kept = @($u.Query.TrimStart('?') -split '&' | Where-Object { $_ -and $_ -notmatch '^page=' })
    $query = @($kept + ('page=' + $Page)) -join '&'
    return ('{0}://{1}{2}?{3}' -f $u.Scheme, $u.Authority, $u.AbsolutePath, $query)
}

function Get-GangplankNextPageUri {
    # The next page of a list response: the RFC 8288 Link header (GitHub, GitLab),
    # else GitLab's X-Next-Page. Known = the response said how paging ends, so a
    # full page with neither header is not guessed at.
    [CmdletBinding()]
    param([hashtable]$Headers,[Parameter(Mandatory)][string]$CurrentUri)
    $next = $null
    $known = $false
    $link = [string]$Headers['link']
    if ($link) {
        $known = $true
        foreach ($entry in ($link -split ',(?=\s*<)')) {
            if ($entry -notmatch '<([^>]*)>') { continue }
            $target = $Matches[1]
            if ($entry -notmatch 'rel\s*=\s*"?([^";]*)"?') { continue }
            $rels = @($Matches[1].Trim() -split '\s+')
            if ($rels -contains 'next') {
                $next = [uri]::new([uri]$CurrentUri, $target).AbsoluteUri
                break
            }
        }
    }
    elseif ($Headers.ContainsKey('x-next-page')) {
        $known = $true
        $n = [string]$Headers['x-next-page']
        if ($n -match '^\d+$') { $next = Set-GangplankPageQuery -Uri $CurrentUri -Page $n }
    }
    return [pscustomobject]@{ Known = $known; Uri = $next }
}

function Invoke-GangplankPagedGet {
    # GET a list endpoint and follow its pages. Pages follow the Link / X-Next-Page
    # headers; a response with neither (a proxy may strip them) is followed by a
    # page=N request while it is full. The token only goes to the host of the first
    # request: a paging link to another host is refused. After MaxPages the list
    # stops with a warning rather than running on.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [int]$PerPage = 100,
        [int]$MaxPages = 50
    )
    $origin = [uri]$Uri
    $items = New-Object System.Collections.Generic.List[object]
    $current = $Uri
    for ($page = 1; $page -le $MaxPages; $page++) {
        $response = Invoke-GangplankHttpRequest -Method GET -Uri $current -Headers $Headers
        $batch = @(ConvertFrom-GangplankApiResponse -Provider $Provider -Method GET -Endpoint ([uri]$current).AbsolutePath -Response $response | Where-Object { $null -ne $_ })
        foreach ($b in $batch) { [void]$items.Add($b) }
        if ($batch.Count -eq 0) { break }
        $paging = Get-GangplankNextPageUri -Headers $response.Headers -CurrentUri $current
        $nextUri = $paging.Uri
        if (-not $paging.Known -and $batch.Count -ge $PerPage) {
            $nextUri = Set-GangplankPageQuery -Uri $current -Page ([string]($page + 1))
        }
        if (-not $nextUri) { break }
        $n = [uri]$nextUri
        if ($n.Scheme -ne $origin.Scheme -or $n.Authority -ne $origin.Authority) {
            throw "NETWORK|$Provider paging link points to another host; the list was not followed."
        }
        $current = $nextUri
        if ($page -eq $MaxPages) { Write-GangplankLog -Level WARN -Message "$Provider list stopped after $MaxPages pages: $(Get-GangplankSafeUrl $Uri)" }
    }
    return @($items.ToArray())
}
