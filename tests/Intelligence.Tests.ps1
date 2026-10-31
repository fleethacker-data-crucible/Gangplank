#Requires -Version 5.1
# AI endpoint discovery, model choice and settings; branch naming; workspace folder.
# Offline: HTTP answers are scripted through the transport seam.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-intel-' + [guid]::NewGuid().ToString('N'))
$names = @('GANGPLANK_AI_URL','LLM_URL','OPENAI_BASE_URL','GANGPLANK_AI_MODEL','LLM_MODEL','OPENAI_MODEL','GANGPLANK_AI_ALLOWED_HOSTS','GANGPLANK_WORK_ROOT','GANGPLANK_AI_TOKEN','GENAI_TOKEN','LLM_TOKEN','OPENAI_API_KEY')
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n,$null) }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    & (Get-Module Gangplank) {
        param($Temp)
        function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
        function Get-Code([scriptblock]$Block) { try { $null = & $Block; return '' } catch { return ([string]$_.Exception.Message -split '\|')[0] } }
        Initialize-GangplankLogging -LogDir (Join-Path $Temp 'Logs') -Level ERROR
        Initialize-GangplankConfig -ConfigPath (Join-Path $Temp 'config/gangplank-config.json')
        $script:GangplankAuditPath = Join-Path $Temp 'Logs/audit.jsonl'

        # --- endpoint policy ---------------------------------------------------
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'http://gateway.example.com/v1' }) -eq 'BAD_REQUEST') 'Plain http to another host must be refused'
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'https://user:pw@gateway.example.com/v1' }) -eq 'BAD_REQUEST') 'Embedded credentials must be refused'
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'http://127.0.0.1:11434' }) -eq '') 'Local model over http should be allowed'
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'https://gateway.example.com/v1' }) -eq '') 'Any HTTPS gateway allowed without an administrator list'
        $env:GANGPLANK_AI_ALLOWED_HOSTS = 'ai.example.com'
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'https://gateway.example.com/v1' }) -eq 'FORBIDDEN') 'The administrator list must be strict'
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'https://ai.example.com/v1' }) -eq '') 'Listed host allowed'
        Assert ((Get-Code { Assert-GangplankAiEndpoint -Url 'https://api.github.com/v1' }) -eq 'FORBIDDEN') 'No built-in host bypasses the administrator list'
        $env:GANGPLANK_AI_ALLOWED_HOSTS = $null

        # --- model filtering and ranking --------------------------------------
        $ranked = @(Select-GangplankAiChatModels -Ids @('text-embedding-3-small','whisper-1','gpt-4o-mini','gpt-4.1','llama-3.1-8b','tts-1','dall-e-3') -Current '')
        Assert ($ranked -notcontains 'text-embedding-3-small' -and $ranked -notcontains 'whisper-1' -and $ranked -notcontains 'tts-1' -and $ranked -notcontains 'dall-e-3') ('Non-chat models must be dropped: ' + ($ranked -join ','))
        Assert ($ranked[0] -eq 'gpt-4.1') ('Best general chat model should come first, got ' + $ranked[0])
        Assert ((@(Select-GangplankAiChatModels -Ids @('gpt-4.1','llama-3.1-8b') -Current 'llama-3.1-8b'))[0] -eq 'llama-3.1-8b') 'The current choice should stay first'

        # --- discovery through scripted HTTP ------------------------------------
        $script:Seen = New-Object System.Collections.Generic.List[object]
        $script:Routes = @{}
        $script:GangplankHttpTransport = {
            param($Request)
            $script:Seen.Add($Request)
            foreach ($k in $script:Routes.Keys) { if ($Request.Uri -like $k) { return $script:Routes[$k] } }
            return [pscustomobject]@{ Status = 404; Headers = @{}; Text = '{}'; File = $null; NetworkError = '' }
        }
        function Reply([int]$Status,$Obj) { [pscustomobject]@{ Status = $Status; Headers = @{}; Text = ($Obj | ConvertTo-Json -Depth 6 -Compress); File = $null; NetworkError = '' } }

        $script:Routes = @{ 'https://gateway.example.com/v1/models' = (Reply 200 @{ data = @(@{ id = 'text-embedding-3-small' }, @{ id = 'gpt-4o-mini' }, @{ id = 'gpt-4.1' }) }) }
        $r = Find-GangplankAiModels -Endpoint 'https://gateway.example.com/v1/chat/completions' -Token 't'
        Assert ($r.profile -eq 'openai' -and $r.recommended -eq 'gpt-4.1') ("OpenAI-compatible detection wrong: $($r.profile) $($r.recommended)")
        Assert ($r.chatUrl -eq 'https://gateway.example.com/v1/chat/completions') ('Chat URL wrong: ' + $r.chatUrl)
        Assert ($script:Seen[0].Headers['Authorization'] -eq 'Bearer t') 'OpenAI-style gateways use a bearer token'

        $script:Seen.Clear()
        $script:Routes = @{ 'https://team.openai.azure.com/openai/deployments*' = (Reply 200 @{ data = @(@{ id = 'chat-4o' }, @{ id = 'embed-small' }) }) }
        $r = Find-GangplankAiModels -Endpoint 'https://team.openai.azure.com' -Token 'az'
        Assert ($r.profile -eq 'azure' -and $r.auth -eq 'api-key') 'Azure should be detected with api-key auth'
        Assert ($script:Seen[0].Headers['api-key'] -eq 'az' -and -not $script:Seen[0].Headers.ContainsKey('Authorization')) 'Azure must send api-key, not a bearer header'
        Assert ($r.chatUrl -like 'https://team.openai.azure.com/openai/deployments/chat-4o/chat/completions?api-version=*') ('Azure chat URL wrong: ' + $r.chatUrl)

        $script:Routes = @{ 'https://adb-1.azuredatabricks.net/api/2.0/serving-endpoints' = (Reply 200 @{ endpoints = @(@{ name = 'claude-sonnet'; task = 'llm/v1/chat' }, @{ name = 'bge-embed'; task = 'llm/v1/embeddings' }) }) }
        $r = Find-GangplankAiModels -Endpoint 'https://adb-1.azuredatabricks.net/serving-endpoints' -Token 'd'
        Assert ($r.profile -eq 'databricks' -and @($r.models).Count -eq 1 -and $r.models[0] -eq 'claude-sonnet') 'Databricks should list chat endpoints only'
        Assert ($r.chatUrl -eq 'https://adb-1.azuredatabricks.net/serving-endpoints/claude-sonnet/invocations') ('Databricks chat URL wrong: ' + $r.chatUrl)

        $script:Routes = @{ 'http://127.0.0.1:11434/api/tags' = (Reply 200 @{ models = @(@{ name = 'llama3.1:8b' }, @{ name = 'nomic-embed-text' }) }) }
        $r = Find-GangplankAiModels -Endpoint 'http://127.0.0.1:11434' -Token ''
        Assert ($r.profile -eq 'ollama' -and $r.recommended -eq 'llama3.1:8b') ("Ollama fallback wrong: $($r.profile) $($r.recommended)")
        Assert ($r.chatUrl -eq 'http://127.0.0.1:11434/v1/chat/completions') ('Ollama chat URL wrong: ' + $r.chatUrl)

        $script:Routes = @{ 'https://gateway.example.com/v1/models' = [pscustomobject]@{ Status = 401; Headers = @{}; Text = '{}'; File = $null; NetworkError = '' } }
        Assert ((Get-Code { Find-GangplankAiModels -Endpoint 'https://gateway.example.com/v1' -Token 'bad' }) -eq 'AUTH_REJECTED') 'A refused token must be reported clearly'
        $script:GangplankHttpTransport = $null

        # --- settings and precedence ---------------------------------------------
        # Default: the local phoenix-lai server on this PC, no token, model phoenixlai.
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Url -eq 'http://127.0.0.1:1234/v1/chat/completions') ('Default AI endpoint should be local phoenix-lai, got ' + $cfg.Url)
        Assert ($cfg.Model -eq 'phoenixlai' -and $cfg.Loopback -and $cfg.Profile -eq 'openai') ('Default model should be phoenixlai on loopback, got ' + $cfg.Model)
        Assert ((Get-GangplankAiSettingsView).source -eq 'default') 'Settings view should report the built-in default'
        Assert (-not (Get-GangplankAiSettingsView).tokenRequired) 'No token is required for the local default'
        Assert ($null -eq (Get-GangplankAiRequestToken -Config $cfg)) 'Loopback without a token: no token, no error'
        $script:Seen = New-Object System.Collections.Generic.List[object]
        $script:Routes = @{ 'http://127.0.0.1:1234/v1/chat/completions' = (Reply 200 @{ choices = @(@{ message = @{ content = 'local answer' } }) }) }
        $script:GangplankHttpTransport = {
            param($Request)
            $script:Seen.Add($Request)
            foreach ($k in $script:Routes.Keys) { if ($Request.Uri -like $k) { return $script:Routes[$k] } }
            return [pscustomobject]@{ Status = 404; Headers = @{}; Text = '{}'; File = $null; NetworkError = '' }
        }
        Assert ((Invoke-GangplankAI -Question 'hi') -eq 'local answer') 'Chat should reach the local default endpoint'
        Assert ($script:Seen.Count -eq 1 -and [string]$script:Seen[0].Uri -eq 'http://127.0.0.1:1234/v1/chat/completions') 'Chat went to the wrong endpoint'
        Assert (-not $script:Seen[0].Headers.ContainsKey('Authorization')) 'No Authorization header may be sent to loopback without a token'
        Assert ((($script:Seen[0].Body | ConvertFrom-Json).model) -eq 'phoenixlai') 'The default request should name the phoenixlai model'
        $env:GANGPLANK_AI_TOKEN = 'local-opt-token'
        $script:Seen.Clear()
        [void](Invoke-GangplankAI -Question 'hi')
        Assert ([string]$script:Seen[0].Headers['Authorization'] -eq 'Bearer local-opt-token') 'An optional loopback token is sent when set'
        $env:GANGPLANK_AI_TOKEN = $null
        $script:GangplankHttpTransport = $null
        # The administrator list never blocks this PC, and still blocks other hosts.
        $env:GANGPLANK_AI_ALLOWED_HOSTS = 'ai.example.com'
        Assert ((Get-GangplankAiConfiguration).Url -eq 'http://127.0.0.1:1234/v1/chat/completions') 'The local default must pass an administrator list'
        $env:LLM_URL = 'https://gateway.example.com/v1'; $env:LLM_MODEL = 'm'
        Assert ((Get-Code { Get-GangplankAiConfiguration }) -eq 'FORBIDDEN') 'An override outside the administrator list must be refused'
        $env:LLM_URL = $null; $env:LLM_MODEL = $null; $env:GANGPLANK_AI_ALLOWED_HOSTS = $null
        # Any loopback override without a model variable uses phoenixlai.
        $env:LLM_URL = 'http://localhost:8080/v1'
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Url -eq 'http://localhost:8080/v1/chat/completions' -and $cfg.Model -eq 'phoenixlai' -and $cfg.Loopback) ('Loopback override wrong: ' + $cfg.Url + ' ' + $cfg.Model)
        $env:LLM_MODEL = 'local-other'
        Assert ((Get-GangplankAiConfiguration).Model -eq 'local-other') 'LLM_MODEL overrides the loopback model'
        # A remote override needs its own model and a token; no external model name is built in.
        $env:LLM_URL = 'https://gateway.example.com/v1'; $env:LLM_MODEL = $null
        Assert ((Get-Code { Get-GangplankAiConfiguration }) -eq 'AI_MODEL_MISSING') 'A remote endpoint without a model must not fall back to a built-in model'
        $env:LLM_MODEL = 'gw-model'
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Url -eq 'https://gateway.example.com/v1/chat/completions' -and $cfg.Model -eq 'gw-model' -and -not $cfg.Loopback) 'Remote override not used'
        Assert ((Get-Code { Get-GangplankAiRequestToken -Config $cfg }) -eq 'AI_TOKEN_MISSING') 'A remote endpoint without a token must be refused'
        Assert ((Get-Code { Invoke-GangplankAI -Question 'hi' }) -eq 'AI_TOKEN_MISSING') 'Chat to a remote endpoint without a token must be refused before any request'
        $env:LLM_TOKEN = 'remote-token'
        Assert ((Get-GangplankAiRequestToken -Config $cfg) -eq 'remote-token') 'A remote endpoint uses the AI token'
        $env:LLM_TOKEN = $null; $env:LLM_URL = $null; $env:LLM_MODEL = $null
        Assert (Test-GangplankAiLoopbackUrl -Url 'http://127.0.0.5:1234/v1') '127.0.0.0/8 is loopback'
        Assert (-not (Test-GangplankAiLoopbackUrl -Url 'https://127.0.0.1.example.com/v1')) 'A look-alike host is not loopback'
        [void](Set-GangplankAiSettings -Endpoint 'https://gateway.example.com/v1' -Flavor 'openai' -Model 'gpt-4.1')
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Model -eq 'gpt-4.1' -and $cfg.Url -eq 'https://gateway.example.com/v1/chat/completions') 'Saved setting not used'
        [void](Set-GangplankAiSettings -Endpoint 'https://adb-1.azuredatabricks.net' -Flavor 'databricks' -Model 'claude-sonnet')
        Assert (-not (Get-GangplankAiConfiguration).Streams) 'Databricks answers in one piece (no streaming)'
        $env:LLM_URL = 'https://halyard-gw.example.com/v1'; $env:LLM_MODEL = 'shared-model'
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Endpoint -eq 'https://halyard-gw.example.com/v1' -and $cfg.Model -eq 'shared-model') 'Halyard variables (LLM_URL/LLM_MODEL) should be honoured'
        $env:LLM_URL = $null; $env:LLM_MODEL = $null
        $env:LLM_TOKEN = 'shared-token-123'
        Assert ((Get-GangplankAiToken) -eq 'shared-token-123') 'LLM_TOKEN (Halyard) should be accepted as the AI token'
        $env:LLM_TOKEN = $null
        [void](Set-GangplankAiSettings -Endpoint '')
        Assert ((Get-GangplankAiConfiguration).Url -eq 'http://127.0.0.1:1234/v1/chat/completions') 'Reset should return to the local phoenix-lai default'
        Assert ((Get-Code { Set-GangplankAiSettings -Endpoint 'https://gateway.example.com/v1' -Model '' }) -eq 'BAD_REQUEST') 'A model is required'

        # --- branch names -----------------------------------------------------------
        Assert ((ConvertTo-GangplankBranchName -Name 'dummy-dev') -eq 'dummy-dev') 'Plain name kept'
        Assert ((ConvertTo-GangplankBranchName -Name '  Dummy dev  ') -eq 'Dummy-dev') 'Spaces become dashes'
        Assert ((ConvertTo-GangplankBranchName -Name 'feature/login') -eq 'feature/login') 'Slashes allowed'
        foreach ($bad in @('a..b','..','x.lock','-','@{x}','bad~name')) {
            Assert ((Get-Code { ConvertTo-GangplankBranchName -Name $bad }) -eq 'BAD_REQUEST') "Invalid branch name accepted: $bad"
        }

        # --- workspace folder ----------------------------------------------------------
        $default = Get-GangplankDefaultWorkspaceRoot
        # <home>\Keystone only while it exists and <home>\Gangplank does not (pre-rename workspaces).
        Assert ($default -match '(Gangplank|Keystone)$') ('Default workspace folder should be <home>\Gangplank, got ' + $default)
        Assert ((Get-GangplankWorkspaceRoot) -eq $default) 'Default in use when nothing is set'
        $toolInside = Join-Path (Split-Path $PSScriptRoot -Parent) 'work'
        Assert ((Get-Code { Set-GangplankWorkspaceRoot -Path $toolInside }) -eq 'BAD_REQUEST') 'Workspaces inside the program folder must be refused'
        Assert ((Get-Code { Set-GangplankWorkspaceRoot -Path '\\server\share\ks' }) -eq 'BAD_REQUEST') 'Network share must be refused'
        $mine = Join-Path $Temp 'my-workspaces'
        Assert ((Set-GangplankWorkspaceRoot -Path $mine) -eq [IO.Path]::GetFullPath($mine)) 'Custom folder not saved'
        Assert (Test-Path -LiteralPath $mine) 'Custom folder should be created'
        $env:GANGPLANK_WORK_ROOT = Join-Path $Temp 'env-root'
        Assert ((Get-GangplankWorkspaceRoot) -eq $env:GANGPLANK_WORK_ROOT) 'GANGPLANK_WORK_ROOT should win'
        $env:GANGPLANK_WORK_ROOT = $null
        [void](Set-GangplankWorkspaceRoot -Path '')
        Assert ((Get-GangplankWorkspaceRoot) -eq $default) 'Reset to default'
        $p = Get-GangplankSafeWorkspacePath -Base $mine -Project 'fleethacker-data-crucible/dumping-grounds' -Branch 'dummy-dev'
        Assert ($p -eq (Join-Path (Join-Path $mine 'dumping-grounds') 'dummy-dev')) ('Workspace layout should be <root>\<repo>\<branch>, got ' + $p)
    } $temp
    Write-Host 'AI discovery, settings, branch naming and workspace folder checks passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
