#Requires -Version 5.1
# AI endpoint discovery, model choice and settings; branch naming; workspace folder.
# Offline: HTTP answers are scripted through the transport seam.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-intel-' + [guid]::NewGuid().ToString('N'))
$names = @('KEYSTONE_AI_URL','LLM_URL','OPENAI_BASE_URL','KEYSTONE_AI_MODEL','LLM_MODEL','OPENAI_MODEL','KEYSTONE_AI_ALLOWED_HOSTS','KEYSTONE_WORK_ROOT','KEYSTONE_AI_TOKEN','GENAI_TOKEN','LLM_TOKEN','OPENAI_API_KEY')
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n,$null) }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
    & (Get-Module Keystone) {
        param($Temp)
        function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
        function Get-Code([scriptblock]$Block) { try { $null = & $Block; return '' } catch { return ([string]$_.Exception.Message -split '\|')[0] } }
        Initialize-KeystoneLogging -LogDir (Join-Path $Temp 'Logs') -Level ERROR
        Initialize-KeystoneConfig -ConfigPath (Join-Path $Temp 'config/keystone-config.json')
        $script:KeystoneAuditPath = Join-Path $Temp 'Logs/audit.jsonl'

        # --- endpoint policy ---------------------------------------------------
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'http://gateway.example.com/v1' }) -eq 'BAD_REQUEST') 'Plain http to another host must be refused'
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'https://user:pw@gateway.example.com/v1' }) -eq 'BAD_REQUEST') 'Embedded credentials must be refused'
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'http://127.0.0.1:11434' }) -eq '') 'Local model over http should be allowed'
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'https://gateway.example.com/v1' }) -eq '') 'Any HTTPS gateway allowed without an administrator list'
        $env:KEYSTONE_AI_ALLOWED_HOSTS = 'ai.example.mil'
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'https://gateway.example.com/v1' }) -eq 'FORBIDDEN') 'The administrator list must be strict'
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'https://ai.example.mil/v1' }) -eq '') 'Listed host allowed'
        Assert ((Get-Code { Assert-KeystoneAiEndpoint -Url 'https://api.genai.mil/v1' }) -eq '') 'The default host stays allowed'
        $env:KEYSTONE_AI_ALLOWED_HOSTS = $null

        # --- model filtering and ranking --------------------------------------
        $ranked = @(Select-KeystoneAiChatModels -Ids @('text-embedding-3-small','whisper-1','gpt-4o-mini','gpt-4.1','llama-3.1-8b','tts-1','dall-e-3') -Current '')
        Assert ($ranked -notcontains 'text-embedding-3-small' -and $ranked -notcontains 'whisper-1' -and $ranked -notcontains 'tts-1' -and $ranked -notcontains 'dall-e-3') ('Non-chat models must be dropped: ' + ($ranked -join ','))
        Assert ($ranked[0] -eq 'gpt-4.1') ('Best general chat model should come first, got ' + $ranked[0])
        Assert ((@(Select-KeystoneAiChatModels -Ids @('gpt-4.1','llama-3.1-8b') -Current 'llama-3.1-8b'))[0] -eq 'llama-3.1-8b') 'The current choice should stay first'

        # --- discovery through scripted HTTP ------------------------------------
        $script:Seen = New-Object System.Collections.Generic.List[object]
        $script:Routes = @{}
        $script:KeystoneHttpTransport = {
            param($Request)
            $script:Seen.Add($Request)
            foreach ($k in $script:Routes.Keys) { if ($Request.Uri -like $k) { return $script:Routes[$k] } }
            return [pscustomobject]@{ Status = 404; Headers = @{}; Text = '{}'; File = $null; NetworkError = '' }
        }
        function Reply([int]$Status,$Obj) { [pscustomobject]@{ Status = $Status; Headers = @{}; Text = ($Obj | ConvertTo-Json -Depth 6 -Compress); File = $null; NetworkError = '' } }

        $script:Routes = @{ 'https://gateway.example.com/v1/models' = (Reply 200 @{ data = @(@{ id = 'text-embedding-3-small' }, @{ id = 'gpt-4o-mini' }, @{ id = 'gpt-4.1' }) }) }
        $r = Find-KeystoneAiModels -Endpoint 'https://gateway.example.com/v1/chat/completions' -Token 't'
        Assert ($r.profile -eq 'openai' -and $r.recommended -eq 'gpt-4.1') ("OpenAI-compatible detection wrong: $($r.profile) $($r.recommended)")
        Assert ($r.chatUrl -eq 'https://gateway.example.com/v1/chat/completions') ('Chat URL wrong: ' + $r.chatUrl)
        Assert ($script:Seen[0].Headers['Authorization'] -eq 'Bearer t') 'OpenAI-style gateways use a bearer token'

        $script:Seen.Clear()
        $script:Routes = @{ 'https://team.openai.azure.com/openai/deployments*' = (Reply 200 @{ data = @(@{ id = 'chat-4o' }, @{ id = 'embed-small' }) }) }
        $r = Find-KeystoneAiModels -Endpoint 'https://team.openai.azure.com' -Token 'az'
        Assert ($r.profile -eq 'azure' -and $r.auth -eq 'api-key') 'Azure should be detected with api-key auth'
        Assert ($script:Seen[0].Headers['api-key'] -eq 'az' -and -not $script:Seen[0].Headers.ContainsKey('Authorization')) 'Azure must send api-key, not a bearer header'
        Assert ($r.chatUrl -like 'https://team.openai.azure.com/openai/deployments/chat-4o/chat/completions?api-version=*') ('Azure chat URL wrong: ' + $r.chatUrl)

        $script:Routes = @{ 'https://adb-1.azuredatabricks.net/api/2.0/serving-endpoints' = (Reply 200 @{ endpoints = @(@{ name = 'claude-sonnet'; task = 'llm/v1/chat' }, @{ name = 'bge-embed'; task = 'llm/v1/embeddings' }) }) }
        $r = Find-KeystoneAiModels -Endpoint 'https://adb-1.azuredatabricks.net/serving-endpoints' -Token 'd'
        Assert ($r.profile -eq 'databricks' -and @($r.models).Count -eq 1 -and $r.models[0] -eq 'claude-sonnet') 'Databricks should list chat endpoints only'
        Assert ($r.chatUrl -eq 'https://adb-1.azuredatabricks.net/serving-endpoints/claude-sonnet/invocations') ('Databricks chat URL wrong: ' + $r.chatUrl)

        $script:Routes = @{ 'http://127.0.0.1:11434/api/tags' = (Reply 200 @{ models = @(@{ name = 'llama3.1:8b' }, @{ name = 'nomic-embed-text' }) }) }
        $r = Find-KeystoneAiModels -Endpoint 'http://127.0.0.1:11434' -Token ''
        Assert ($r.profile -eq 'ollama' -and $r.recommended -eq 'llama3.1:8b') ("Ollama fallback wrong: $($r.profile) $($r.recommended)")
        Assert ($r.chatUrl -eq 'http://127.0.0.1:11434/v1/chat/completions') ('Ollama chat URL wrong: ' + $r.chatUrl)

        $script:Routes = @{ 'https://gateway.example.com/v1/models' = [pscustomobject]@{ Status = 401; Headers = @{}; Text = '{}'; File = $null; NetworkError = '' } }
        Assert ((Get-Code { Find-KeystoneAiModels -Endpoint 'https://gateway.example.com/v1' -Token 'bad' }) -eq 'AUTH_REJECTED') 'A refused token must be reported clearly'
        $script:KeystoneHttpTransport = $null

        # --- settings and precedence ---------------------------------------------
        $cfg = Get-KeystoneAiConfiguration
        Assert ($cfg.Endpoint -eq 'https://api.genai.mil/v1' -and $cfg.Url -eq 'https://api.genai.mil/v1/chat/completions') 'Default should stay genai.mil'
        [void](Set-KeystoneAiSettings -Endpoint 'https://gateway.example.com/v1' -Flavor 'openai' -Model 'gpt-4.1')
        $cfg = Get-KeystoneAiConfiguration
        Assert ($cfg.Model -eq 'gpt-4.1' -and $cfg.Url -eq 'https://gateway.example.com/v1/chat/completions') 'Saved setting not used'
        [void](Set-KeystoneAiSettings -Endpoint 'https://adb-1.azuredatabricks.net' -Flavor 'databricks' -Model 'claude-sonnet')
        Assert (-not (Get-KeystoneAiConfiguration).Streams) 'Databricks answers in one piece (no streaming)'
        $env:LLM_URL = 'https://cascade-gw.example.com/v1'; $env:LLM_MODEL = 'shared-model'
        $cfg = Get-KeystoneAiConfiguration
        Assert ($cfg.Endpoint -eq 'https://cascade-gw.example.com/v1' -and $cfg.Model -eq 'shared-model') 'Cascade variables (LLM_URL/LLM_MODEL) should be honoured'
        $env:LLM_URL = $null; $env:LLM_MODEL = $null
        $env:LLM_TOKEN = 'shared-token-123'
        Assert ((Get-KeystoneAiToken) -eq 'shared-token-123') 'LLM_TOKEN (Cascade) should be accepted as the GenAI token'
        $env:LLM_TOKEN = $null
        [void](Set-KeystoneAiSettings -Endpoint '')
        Assert ((Get-KeystoneAiConfiguration).Endpoint -eq 'https://api.genai.mil/v1') 'Reset should return to the default'
        Assert ((Get-Code { Set-KeystoneAiSettings -Endpoint 'https://gateway.example.com/v1' -Model '' }) -eq 'BAD_REQUEST') 'A model is required'

        # --- branch names -----------------------------------------------------------
        Assert ((ConvertTo-KeystoneBranchName -Name 'dummy-dev') -eq 'dummy-dev') 'Plain name kept'
        Assert ((ConvertTo-KeystoneBranchName -Name '  Dummy dev  ') -eq 'Dummy-dev') 'Spaces become dashes'
        Assert ((ConvertTo-KeystoneBranchName -Name 'feature/login') -eq 'feature/login') 'Slashes allowed'
        foreach ($bad in @('a..b','..','x.lock','-','@{x}','bad~name')) {
            Assert ((Get-Code { ConvertTo-KeystoneBranchName -Name $bad }) -eq 'BAD_REQUEST') "Invalid branch name accepted: $bad"
        }

        # --- workspace folder ----------------------------------------------------------
        $default = Get-KeystoneDefaultWorkspaceRoot
        Assert ($default -match 'Keystone$') ('Default workspace folder should be <home>\Keystone, got ' + $default)
        Assert ((Get-KeystoneWorkspaceRoot) -eq $default) 'Default in use when nothing is set'
        $toolInside = Join-Path (Split-Path $PSScriptRoot -Parent) 'work'
        Assert ((Get-Code { Set-KeystoneWorkspaceRoot -Path $toolInside }) -eq 'BAD_REQUEST') 'Workspaces inside the program folder must be refused'
        Assert ((Get-Code { Set-KeystoneWorkspaceRoot -Path '\\server\share\ks' }) -eq 'BAD_REQUEST') 'Network share must be refused'
        $mine = Join-Path $Temp 'my-workspaces'
        Assert ((Set-KeystoneWorkspaceRoot -Path $mine) -eq [IO.Path]::GetFullPath($mine)) 'Custom folder not saved'
        Assert (Test-Path -LiteralPath $mine) 'Custom folder should be created'
        $env:KEYSTONE_WORK_ROOT = Join-Path $Temp 'env-root'
        Assert ((Get-KeystoneWorkspaceRoot) -eq $env:KEYSTONE_WORK_ROOT) 'KEYSTONE_WORK_ROOT should win'
        $env:KEYSTONE_WORK_ROOT = $null
        [void](Set-KeystoneWorkspaceRoot -Path '')
        Assert ((Get-KeystoneWorkspaceRoot) -eq $default) 'Reset to default'
        $p = Get-KeystoneSafeWorkspacePath -Base $mine -Project 'sun-of-anton/dumping-grounds' -Branch 'dummy-dev'
        Assert ($p -eq (Join-Path (Join-Path $mine 'dumping-grounds') 'dummy-dev')) ('Workspace layout should be <root>\<repo>\<branch>, got ' + $p)
    } $temp
    Write-Host 'AI discovery, settings, branch naming and workspace folder checks passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
