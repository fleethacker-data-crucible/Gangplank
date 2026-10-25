#Requires -Version 5.1
# ============================================================
#  Core/Intelligence.ps1 - one AI setting, any gateway
#  The user gives an endpoint; Gangplank works out what it is and which chat
#  models it offers:
#    openai      OpenAI-compatible (/v1/models + /v1/chat/completions): genai.mil,
#                OpenAI, LiteLLM, LM Studio, vLLM, most gateways
#    azure       Azure OpenAI (*.openai.azure.com): deployments, api-key header
#    databricks  Databricks model serving (/serving-endpoints/<name>/invocations)
#    ollama      local Ollama (/api/tags; chat through its /v1 endpoint)
#  Settings (non-secret) live in config\keystone.local.json Intelligence; the token
#  is the GenAi credential (environment, Gangplank's store, or Lazarette).
#  Environment names shared with Halyard are honoured: LLM_URL / OPENAI_BASE_URL,
#  LLM_MODEL / OPENAI_MODEL, LLM_TOKEN / OPENAI_API_KEY.
# ============================================================

$script:GangplankAiDefaultEndpoint = 'https://api.genai.mil/v1'
$script:GangplankAiDefaultModel = 'gemini-3.8-flash'
$script:GangplankAiAzureApiVersion = '2024-10-21'
# Not chat models: never offered, never auto-picked.
$script:GangplankAiNotChat = '(?i)(embed|whisper|tts|speech|audio|transcri|dall-?e|image-gen|moderation|rerank|davinci-00|babbage|ada-00|text-similarity|search-)'
# Preference when nothing is chosen yet: broadly capable chat families first.
$script:GangplankAiPreferred = @('(?i)gpt-4\.1(?!-nano)','(?i)gpt-4o(?!-mini-audio)','(?i)claude','(?i)gemini.*(pro|flash)','(?i)llama-?3','(?i)mistral-(large|medium)','(?i)qwen','(?i)gpt-4o-mini','(?i)gpt')

function Get-GangplankAiEnvironment {
    # @{ Endpoint; Model } from the environment, or empty strings.
    $endpoint = ''
    foreach ($n in @('GANGPLANK_AI_URL','LLM_URL','OPENAI_BASE_URL')) { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $endpoint = $v.Trim(); break } }
    $model = ''
    foreach ($n in @('GANGPLANK_AI_MODEL','LLM_MODEL','OPENAI_MODEL')) { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $model = $v.Trim(); break } }
    return @{ Endpoint = $endpoint; Model = $model }
}

function Get-GangplankAiAllowedHosts {
    # Administrator allowlist (GANGPLANK_AI_ALLOWED_HOSTS). When set it is strict.
    $list = @()
    if ((Get-GangplankEnv AI_ALLOWED_HOSTS)) {
        $list = @((Get-GangplankEnv AI_ALLOWED_HOSTS) -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    return $list
}

function Assert-GangplankAiEndpoint {
    # HTTPS (http only for this PC: local Ollama or LM Studio), no embedded
    # credentials, and inside the administrator allowlist when one is set.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url.Trim(),[UriKind]::Absolute,[ref]$u) -or $u.UserInfo) { throw 'BAD_REQUEST|Enter the AI endpoint as a full address, for example https://api.genai.mil/v1.' }
    $hostName = $u.Host.ToLowerInvariant()
    $loopback = $hostName -in @('127.0.0.1','localhost','[::1]','::1')
    if ($u.Scheme -ne 'https' -and -not ($u.Scheme -eq 'http' -and $loopback)) { throw 'BAD_REQUEST|The AI endpoint must use HTTPS (plain http only for a model running on this PC).' }
    $allowed = @(Get-GangplankAiAllowedHosts)
    if ($allowed.Count -gt 0 -and -not $loopback -and $hostName -notin ($allowed + @('api.genai.mil'))) {
        throw "FORBIDDEN|Your administrator limits AI to: $($allowed -join ', '). $hostName is not on that list."
    }
    return $u
}

function Get-GangplankAiFlavor {
    # Best guess from the address alone; discovery confirms it.
    param([Parameter(Mandatory)][uri]$Uri)
    if ($Uri.Host -match '(?i)\.(openai\.azure\.com|cognitiveservices\.azure\.com)$') { return 'azure' }
    if ($Uri.AbsolutePath -match '(?i)/serving-endpoints(/|$)' -or $Uri.Host -match '(?i)\.(cloud\.databricks\.com|azuredatabricks\.net|gcp\.databricks\.com)$') { return 'databricks' }
    if ($Uri.Port -eq 11434) { return 'ollama' }
    return 'openai'
}

function Get-GangplankAiOrigin { param([uri]$Uri) return $Uri.GetLeftPart([UriPartial]::Authority) }

function Get-GangplankAiOpenAiBase {
    # Accepts .../v1, .../v1/chat/completions, or a bare host; returns the /v1-style base.
    param([Parameter(Mandatory)][uri]$Uri)
    $path = $Uri.AbsolutePath.TrimEnd('/')
    $path = $path -replace '(?i)/chat/completions$',''
    if (-not $path) { $path = '/v1' }
    return (Get-GangplankAiOrigin $Uri) + $path
}

function Get-GangplankAiAuthHeaders {
    param([string]$Auth,[string]$Token)
    $h = @{ 'Content-Type' = 'application/json'; Accept = 'application/json' }
    if ($Token) {
        if ($Auth -eq 'api-key') { $h['api-key'] = $Token } else { $h['Authorization'] = "Bearer $Token" }
    }
    return $h
}

function Get-GangplankAiChatUrl {
    param([Parameter(Mandatory)][string]$Flavor,[Parameter(Mandatory)][string]$Base,[string]$Model)
    switch ($Flavor) {
        'azure' { return ('{0}/openai/deployments/{1}/chat/completions?api-version={2}' -f $Base, [uri]::EscapeDataString($Model), $script:GangplankAiAzureApiVersion) }
        'databricks' { return ('{0}/serving-endpoints/{1}/invocations' -f $Base, [uri]::EscapeDataString($Model)) }
        'ollama' { return ($Base + '/v1/chat/completions') }
        default { return ($Base + '/chat/completions') }
    }
}

function Select-GangplankAiChatModels {
    # Chat-capable ids, best first: the current choice, then preferred families, then the rest.
    param([string[]]$Ids,[string]$Current)
    $chat = @($Ids | Where-Object { $_ -and $_ -notmatch $script:GangplankAiNotChat } | Sort-Object -Unique)
    $rank = {
        param($id)
        if ($Current -and $id -eq $Current) { return -1 }
        for ($i = 0; $i -lt $script:GangplankAiPreferred.Count; $i++) { if ($id -match $script:GangplankAiPreferred[$i]) { return $i } }
        return 99
    }
    return @($chat | Sort-Object @{ Expression = { & $rank $_ } }, @{ Expression = { $_ } })
}

function Find-GangplankAiModels {
    # Ask the endpoint what it is and which chat models it offers. Returns
    # @{ profile; base; auth; models[]; recommended; chatUrl; note }.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Endpoint,[string]$Token,[string]$Current)
    $uri = Assert-GangplankAiEndpoint -Url $Endpoint
    $flavor = Get-GangplankAiFlavor -Uri $uri
    $origin = Get-GangplankAiOrigin $uri
    $ids = @(); $note = ''; $auth = 'bearer'; $base = $origin
    $get = {
        param($Url,$AuthStyle)
        $r = Invoke-GangplankHttpRequest -Method GET -Uri $Url -Headers (Get-GangplankAiAuthHeaders -Auth $AuthStyle -Token $Token) -TimeoutSec 20 -MaxAttempts 1
        if ($r.Status -ge 200 -and $r.Status -lt 300 -and $r.Text) { return ($r.Text | ConvertFrom-Json) }
        if ($r.Status -in @(401,403)) { throw ("{0}|The endpoint refused the GenAI token (HTTP {1}). Check the token in Credentials." -f (Get-GangplankProviderErrorCode -Status $r.Status -Headers $r.Headers), $r.Status) }
        return $null
    }
    if ($flavor -eq 'azure') {
        $auth = 'api-key'
        $doc = & $get ("$origin/openai/deployments?api-version=2022-12-01") 'api-key'
        if ($doc -and $doc.data) { $ids = @($doc.data | ForEach-Object { [string]$_.id }) }
        else { $note = 'Azure did not list deployments; type your deployment name as the model.' }
    } elseif ($flavor -eq 'databricks') {
        $doc = & $get ("$origin/api/2.0/serving-endpoints") 'bearer'
        if ($doc -and $doc.endpoints) {
            $ids = @($doc.endpoints | Where-Object { -not $_.task -or [string]$_.task -match 'chat|completions' } | ForEach-Object { [string]$_.name })
        } else { $note = 'Databricks did not list serving endpoints; type the endpoint name as the model.' }
    } else {
        $openAiBase = Get-GangplankAiOpenAiBase -Uri $uri
        $doc = $null
        foreach ($candidate in @($openAiBase, ($origin + '/v1')) | Select-Object -Unique) {
            $doc = & $get ($candidate + '/models') 'bearer'
            if ($doc -and ($doc.data -or $doc.models)) { $base = $candidate; break }
        }
        if ($doc -and $doc.data) { $ids = @($doc.data | ForEach-Object { [string]$_.id }); $flavor = 'openai' }
        elseif ($doc -and $doc.models) { $ids = @($doc.models | ForEach-Object { if ($_.id) { [string]$_.id } else { [string]$_.name } }); $flavor = 'openai' }
        else {
            # Not OpenAI-shaped: maybe a local Ollama.
            $tags = & $get ($origin + '/api/tags') 'bearer'
            if ($tags -and $tags.models) { $flavor = 'ollama'; $base = $origin; $ids = @($tags.models | ForEach-Object { [string]$_.name }) }
            else { $base = $openAiBase; $note = 'The endpoint did not list its models; type the model name.' }
        }
    }
    if ($flavor -in @('azure','databricks')) { $base = $origin }
    $models = @(Select-GangplankAiChatModels -Ids $ids -Current $Current)
    $recommended = if ($models.Count -gt 0) { $models[0] } else { $Current }
    return [ordered]@{
        profile = $flavor; base = $base; auth = $auth
        models = $models; recommended = $recommended
        chatUrl = $(if ($recommended) { Get-GangplankAiChatUrl -Flavor $flavor -Base $base -Model $recommended } else { '' })
        note = $note
    }
}

function Get-GangplankAiSettingsView {
    $s = (Get-GangplankLocalSettings).Intelligence
    $envAi = Get-GangplankAiEnvironment
    $cred = @((Get-GangplankCredentialStatus).credentials | Where-Object { $_.provider -eq 'GenAi' })[0]
    $cfg = $null; $problem = ''
    try { $cfg = Get-GangplankAiConfiguration } catch { $problem = ([string]$_.Exception.Message -split '\|',2)[-1] }
    return [ordered]@{
        endpoint = $(if ($cfg) { $cfg.Endpoint } else { [string]$s.Endpoint })
        profile = $(if ($cfg) { $cfg.Profile } else { [string]$s.Profile })
        model = $(if ($cfg) { $cfg.Model } else { [string]$s.Model })
        source = $(if ($envAi.Endpoint -or $envAi.Model) { 'environment' } elseif ($s.Endpoint) { 'settings' } else { 'default' })
        tokenReady = [bool]$cred.configured
        allowedHosts = @(Get-GangplankAiAllowedHosts)
        problem = $problem
    }
}

function Set-GangplankAiSettings {
    [CmdletBinding()]
    param([string]$Endpoint,[string]$Flavor,[string]$Model,[string]$Base,[string]$Auth)
    $settings = Get-GangplankLocalSettings
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        foreach ($k in @('Endpoint','Profile','Model','ChatUrl','Auth')) { $settings.Intelligence[$k] = '' }
    } else {
        $uri = Assert-GangplankAiEndpoint -Url $Endpoint
        if ($Flavor -notin @('openai','azure','databricks','ollama')) { $Flavor = Get-GangplankAiFlavor -Uri $uri }
        $m = ([string]$Model).Trim()
        if (-not $m -or $m.Length -gt 200 -or $m -match '[\x00-\x1f]') { throw 'BAD_REQUEST|Choose or type a model name.' }
        if (-not $Base) { $Base = $(if ($Flavor -eq 'openai') { Get-GangplankAiOpenAiBase -Uri $uri } else { Get-GangplankAiOrigin $uri }) }
        [void](Assert-GangplankAiEndpoint -Url $Base)
        $settings.Intelligence.Endpoint = $uri.AbsoluteUri.TrimEnd('/')
        $settings.Intelligence.Profile = $Flavor
        $settings.Intelligence.Model = $m
        $settings.Intelligence.ChatUrl = Get-GangplankAiChatUrl -Flavor $Flavor -Base $Base.TrimEnd('/') -Model $m
        $settings.Intelligence.Auth = $(if ($Auth -eq 'api-key' -or $Flavor -eq 'azure') { 'api-key' } else { 'bearer' })
    }
    Save-GangplankLocalSettings -Settings $settings
    Write-GangplankAudit -Action 'ai.settings' -Data @{ endpoint = [string]$settings.Intelligence.Endpoint; model = [string]$settings.Intelligence.Model; profile = [string]$settings.Intelligence.Profile }
    return (Get-GangplankAiSettingsView)
}

function Get-GangplankAiConfiguration {
    # The chat call to make: environment first (shared with Halyard), then saved
    # settings, then the genai.mil default. Every address passes the same checks.
    $envAi = Get-GangplankAiEnvironment
    $saved = (Get-GangplankLocalSettings).Intelligence
    if ($envAi.Endpoint) {
        $uri = Assert-GangplankAiEndpoint -Url $envAi.Endpoint
        $flavorName = Get-GangplankAiFlavor -Uri $uri
        $model = if ($envAi.Model) { $envAi.Model } elseif ($saved.Model) { [string]$saved.Model } else { $script:GangplankAiDefaultModel }
        $base = if ($flavorName -eq 'openai') { Get-GangplankAiOpenAiBase -Uri $uri } else { Get-GangplankAiOrigin $uri }
        $chat = if ($uri.AbsolutePath -match '(?i)/(chat/completions|invocations)$') { $uri.AbsoluteUri } else { Get-GangplankAiChatUrl -Flavor $flavorName -Base $base -Model $model }
        $auth = if ($flavorName -eq 'azure') { 'api-key' } else { 'bearer' }
        $endpoint = $envAi.Endpoint
    } elseif ($saved.Endpoint -and $saved.ChatUrl) {
        [void](Assert-GangplankAiEndpoint -Url ([string]$saved.ChatUrl))
        $flavorName = [string]$saved.Profile; $model = [string]$saved.Model; $chat = [string]$saved.ChatUrl
        $auth = if ($saved.Auth -eq 'api-key') { 'api-key' } else { 'bearer' }
        $endpoint = [string]$saved.Endpoint
    } else {
        $flavorName = 'openai'
        $model = if ($envAi.Model) { $envAi.Model } else { $script:GangplankAiDefaultModel }
        $chat = $script:GangplankAiDefaultEndpoint + '/chat/completions'
        $auth = 'bearer'; $endpoint = $script:GangplankAiDefaultEndpoint
    }
    return [pscustomobject]@{
        Endpoint = $endpoint; Profile = $flavorName; Model = $model; Url = $chat; Auth = $auth
        # Databricks serving and some gateways do not stream: ask once, show the whole answer.
        Streams = ($flavorName -ne 'databricks')
    }
}

function Get-GangplankAiAnswerText {
    # The assistant text from the response shapes gateways return.
    param($Response)
    if ($null -eq $Response) { return '' }
    $choices = $Response.PSObject.Properties['choices']
    if ($choices -and @($choices.Value).Count -gt 0) {
        $first = @($choices.Value)[0]
        $msg = $first.PSObject.Properties['message']
        if ($msg -and $msg.Value) {
            $content = $msg.Value.PSObject.Properties['content']
            if ($content -and $content.Value -is [string]) { return [string]$content.Value }
            if ($content -and $content.Value) { return (@($content.Value | ForEach-Object { if ($_.text) { [string]$_.text } elseif ($_ -is [string]) { $_ } }) -join '') }
        }
        if ($first.PSObject.Properties['text']) { return [string]$first.text }
    }
    foreach ($k in @('output_text','text','content','result')) {
        $p = $Response.PSObject.Properties[$k]
        if ($p -and $p.Value -is [string]) { return [string]$p.Value }
    }
    return ''
}

function Test-GangplankAiConnection {
    # A tiny real request, so "configured" means "works".
    [CmdletBinding()]
    param([string]$Token)
    $config = Get-GangplankAiConfiguration
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $payload = @{ model = $config.Model; messages = @(@{ role = 'user'; content = 'Reply with the single word OK.' }); max_tokens = 5; temperature = 0 }
    if ($config.Profile -eq 'databricks') { $payload.Remove('model') }
    $r = Invoke-GangplankHttpRequest -Method POST -Uri $config.Url -Headers (Get-GangplankAiAuthHeaders -Auth $config.Auth -Token $Token) -Body ($payload | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 30
    $doc = ConvertFrom-GangplankApiResponse -Provider 'AI' -Method POST -Endpoint (Get-GangplankSafeUrl $config.Url) -Response $r
    $text = Get-GangplankAiAnswerText -Response $doc
    return [ordered]@{ ok = $true; model = $config.Model; profile = $config.Profile; milliseconds = [int]$clock.ElapsedMilliseconds; reply = $(if ($text.Length -gt 40) { $text.Substring(0,40) } else { $text }) }
}
