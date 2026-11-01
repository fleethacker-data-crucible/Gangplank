#Requires -Version 5.1
# The Fairlead client (address, route, key from Credential Manager); branch naming; workspace folder.
# Offline: HTTP answers are scripted through the transport seam, and the key reader is replaced.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-intel-' + [guid]::NewGuid().ToString('N'))
$names = @('GANGPLANK_FAIRLEAD_URL','GANGPLANK_FAIRLEAD_MODEL','GANGPLANK_FAIRLEAD_TARGET','GANGPLANK_WORK_ROOT','LLM_TOKEN','OPENAI_API_KEY')
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
        function Reply([int]$Status,$Obj) { [pscustomobject]@{ Status = $Status; Headers = @{}; Text = ($Obj | ConvertTo-Json -Depth 6 -Compress); File = $null; NetworkError = '' } }
        Initialize-GangplankLogging -LogDir (Join-Path $Temp 'Logs') -Level ERROR
        Initialize-GangplankConfig -ConfigPath (Join-Path $Temp 'config/gangplank-config.json')
        $script:GangplankAuditPath = Join-Path $Temp 'Logs/audit.jsonl'

        # --- address: this PC only -----------------------------------------------
        Assert ((Resolve-GangplankFairleadUrl -Url 'http://127.0.0.1:8776') -eq 'http://127.0.0.1:8776/v1/chat/completions') 'A bare address should get the chat path'
        Assert ((Resolve-GangplankFairleadUrl -Url 'http://127.0.0.1:8776/v1') -eq 'http://127.0.0.1:8776/v1/chat/completions') '/v1 should get the chat path'
        Assert ((Resolve-GangplankFairleadUrl -Url 'http://localhost:9000/v1/chat/completions/') -eq 'http://localhost:9000/v1/chat/completions') 'A full chat address should be kept'
        Assert ((Get-Code { Resolve-GangplankFairleadUrl -Url 'https://gateway.example.com/v1' }) -eq 'FORBIDDEN') 'A remote host must be refused'
        Assert ((Get-Code { Resolve-GangplankFairleadUrl -Url 'http://user:pw@127.0.0.1:8776' }) -eq 'BAD_REQUEST') 'Embedded credentials must be refused'
        Assert ((Get-Code { Resolve-GangplankFairleadUrl -Url 'ftp://127.0.0.1/x' }) -eq 'BAD_REQUEST') 'Only http and https'
        Assert ((Get-Code { Resolve-GangplankFairleadUrl -Url 'not a url' }) -eq 'BAD_REQUEST') 'Not an address'

        # --- defaults and overrides ---------------------------------------------
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Url -eq 'http://127.0.0.1:8776/v1/chat/completions') ('Default address should be Fairlead on this PC, got ' + $cfg.Url)
        Assert ($cfg.Model -eq 'auto') ('Default route should be auto, got ' + $cfg.Model)
        $env:GANGPLANK_FAIRLEAD_URL = 'http://127.0.0.1:9100'; $env:GANGPLANK_FAIRLEAD_MODEL = 'smart'
        $cfg = Get-GangplankAiConfiguration
        Assert ($cfg.Url -eq 'http://127.0.0.1:9100/v1/chat/completions' -and $cfg.Model -eq 'smart') 'GANGPLANK_FAIRLEAD_URL and _MODEL should override'
        $env:GANGPLANK_FAIRLEAD_URL = 'https://gateway.example.com'
        Assert ((Get-Code { Get-GangplankAiConfiguration }) -eq 'FORBIDDEN') 'A remote address in the variable must be refused'
        Assert ([bool](Get-GangplankAiSettingsView).problem) 'The settings view should say what is wrong'
        $env:GANGPLANK_FAIRLEAD_URL = $null; $env:GANGPLANK_FAIRLEAD_MODEL = $null

        # --- the client key: Credential Manager only -------------------------------
        Assert ((Get-GangplankFairleadTarget) -eq 'Fairlead/Gangplank') 'Default credential target'
        $env:GANGPLANK_FAIRLEAD_TARGET = 'Fairlead/Gangplank-test'
        Assert ((Get-GangplankFairleadTarget) -eq 'Fairlead/Gangplank-test') 'A Fairlead/<App> target may be named (tests)'
        foreach ($bad in @('Other/Thing','Fairlead/','Fairlead/../x','Fairlead/a b','gitlab')) {
            $env:GANGPLANK_FAIRLEAD_TARGET = $bad
            Assert ((Get-Code { Get-GangplankFairleadTarget }) -eq 'AI_TOKEN_MISSING') "Target outside Fairlead/ accepted: $bad"
        }
        $env:GANGPLANK_FAIRLEAD_TARGET = $null
        $blob = [Text.Encoding]::Unicode.GetBytes('fl-abc123DEF')
        Assert ((ConvertFrom-GangplankCredentialBlob -Blob $blob) -eq 'fl-abc123DEF') 'UTF-16 blob should decode'
        Assert ((ConvertFrom-GangplankCredentialBlob -Blob ([Text.Encoding]::UTF8.GetBytes('fl-abc123DEF'))) -eq 'fl-abc123DEF') 'UTF-8 blob should decode'
        Assert ($null -eq (ConvertFrom-GangplankCredentialBlob -Blob ([byte[]]@(0xff,0xfe,0x01,0x00)))) 'Binary data is not a key'
        Assert ($null -eq (ConvertFrom-GangplankCredentialBlob -Blob $null)) 'No blob, no key'
        # Environment variables and vault items are never keys for Fairlead.
        $env:LLM_TOKEN = 'not-a-fairlead-key'; $env:OPENAI_API_KEY = 'not-a-fairlead-key'
        Set-GangplankFairleadKeyReader -Reader { param($Target) $null }
        Assert ($null -eq (Get-GangplankFairleadKey)) 'Environment variables must not be used as the key'
        Assert ((Get-Code { Get-GangplankAiRequestToken -Config (Get-GangplankAiConfiguration) }) -eq 'AI_TOKEN_MISSING') 'A missing key should say so'
        Assert (-not (Get-GangplankAiSettingsView).keyReady) 'Settings view: key not ready'
        $env:LLM_TOKEN = $null; $env:OPENAI_API_KEY = $null
        $script:ReadTargets = New-Object System.Collections.Generic.List[string]
        Set-GangplankFairleadKeyReader -Reader { param($Target) $script:ReadTargets.Add($Target); 'fl-test-key-1' }
        Assert ((Get-GangplankAiRequestToken -Config (Get-GangplankAiConfiguration)) -eq 'fl-test-key-1') 'The key should come from the reader'
        Assert ((Get-GangplankAiSettingsView).keyReady) 'Settings view: key ready'
        Assert ($script:ReadTargets[0] -eq 'Fairlead/Gangplank') 'The key is read from Fairlead/Gangplank'

        # --- a chat request through scripted HTTP ----------------------------------
        $script:Seen = New-Object System.Collections.Generic.List[object]
        $script:Routes = @{ 'http://127.0.0.1:8776/v1/chat/completions' = (Reply 200 @{ choices = @(@{ message = @{ content = 'local answer' } }) }) }
        $script:GangplankHttpTransport = {
            param($Request)
            $script:Seen.Add($Request)
            foreach ($k in $script:Routes.Keys) { if ($Request.Uri -like $k) { return $script:Routes[$k] } }
            return [pscustomobject]@{ Status = 404; Headers = @{}; Text = '{}'; File = $null; NetworkError = '' }
        }
        Assert ((Invoke-GangplankAI -Question 'hi') -eq 'local answer') 'Chat should reach Fairlead'
        Assert ($script:Seen.Count -eq 1 -and [string]$script:Seen[0].Uri -eq 'http://127.0.0.1:8776/v1/chat/completions') 'Chat went to the wrong address'
        $h = $script:Seen[0].Headers
        Assert ([string]$h['Authorization'] -eq 'Bearer fl-test-key-1') 'The key is sent as a bearer token'
        Assert ([string]$h['X-Fairlead-Label'] -eq 'Gangplank') 'The app label is sent'
        Assert ([string]$h['X-Fairlead-Privacy'] -eq 'local') 'Requests ask Fairlead to keep them on this PC'
        Assert (-not $h.ContainsKey('api-key')) 'No provider-style key header'
        Assert ((($script:Seen[0].Body | ConvertFrom-Json).model) -eq 'auto') 'The request asks for route auto'
        Set-GangplankFairleadKeyReader -Reader { param($Target) $null }
        $script:Seen.Clear()
        Assert ((Get-Code { Invoke-GangplankAI -Question 'hi' }) -eq 'AI_TOKEN_MISSING') 'No key: refuse before any request leaves'
        Assert ($script:Seen.Count -eq 0) 'Nothing may be sent without a key'
        $t = Test-GangplankAiConnection -Token 'fl-test-key-1'
        Assert ($t.ok -and $t.model -eq 'auto') 'The connection test should go through Fairlead'
        Set-GangplankFairleadKeyReader -Reader $null

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
    Write-Host 'Fairlead client, branch naming and workspace folder checks passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
