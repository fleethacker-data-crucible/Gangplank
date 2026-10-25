#Requires -Version 5.1
# Credential sources and opt-in Lazarette. Uses temp folders for the store, config and
# audit log. On Windows the real DPAPI protector is exercised; elsewhere a test
# protector is injected in-process (nothing outside the process can do that).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-cred-' + [guid]::NewGuid().ToString('N'))
$names = @('GITHUB_TOKEN','GITLAB_TOKEN','GENAI_TOKEN','GANGPLANK_AI_TOKEN','GANGPLANK_LAZARETTE_PATH','ARC_PATH','ARC_ROOT','ARC_HOME')
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n,$null) }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    & (Get-Module Gangplank) {
        param($Temp)
        function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
        function Get-Code([scriptblock]$Block) { try { & $Block; return '' } catch { return ([string]$_.Exception.Message -split '\|')[0] } }
        Initialize-GangplankLogging -LogDir (Join-Path $Temp 'Logs') -Level ERROR
        Initialize-GangplankConfig -ConfigPath (Join-Path $Temp 'config/keystone-config.json')
        $script:GangplankCredentialStorePath = Join-Path $Temp 'store/credentials.json'
        $script:GangplankAuditPath = Join-Path $Temp 'Logs/audit.jsonl'

        # Nothing configured: a clear, coded error.
        Assert ((Get-Code { Resolve-GangplankCredential -Provider GitHub }) -eq 'CREDENTIAL_MISSING') 'Missing credential must be CREDENTIAL_MISSING'
        Assert ((Get-Code { Resolve-GangplankCredential -Provider Jira }) -eq 'BAD_REQUEST') 'Unknown provider must be rejected'

        # Lazarette is never picked up from ARC_PATH or other tools' settings.
        $arc = Join-Path $Temp 'arc'
        [void](New-Item -ItemType Directory -Path (Join-Path $arc 'lib') -Force)
        [IO.File]::WriteAllText((Join-Path (Join-Path $arc 'lib') 'Arc.ps1'),'function Test-ArcVaultUnlocked { $false }')
        $env:ARC_PATH = $arc; $env:ARC_HOME = $arc
        Assert ($null -eq (Find-GangplankLazaretteRoot)) 'ARC_PATH must not enable Lazarette; it is opt-in'
        Assert (-not (Test-GangplankLazaretteConfigured)) 'Lazarette must start unconfigured'
        $init = Initialize-GangplankLazaretteAuthentication -Quiet
        Assert (-not $init.Configured -and -not $init.Loaded) 'Unconfigured Lazarette must not load or prompt'
        Assert ((Get-GangplankLazaretteConnectionStatus).code -eq 'ARC_NOT_CONFIGURED') 'Status must say Lazarette is not configured'
        $env:ARC_PATH = $null; $env:ARC_HOME = $null

        # Lazarette settings are validated and stored as a path only.
        Assert ((Get-Code { Set-GangplankLazaretteSettings -Enabled $true -Path '' }) -eq 'BAD_REQUEST') 'Enabling needs a path'
        Assert ((Get-Code { Set-GangplankLazaretteSettings -Enabled $true -Path 'relative\arc' }) -eq 'BAD_REQUEST') 'Relative path must be rejected'
        Assert ((Get-Code { Set-GangplankLazaretteSettings -Enabled $true -Path (Join-Path $Temp 'nowhere') }) -eq 'BAD_REQUEST') 'Folder without Lazarette must be rejected'
        Assert ((Get-Code { Set-GangplankLazaretteSettings -Enabled $true -Path '\\fileserver\share\arc' }) -eq 'BAD_REQUEST') 'Lazarette on a network share must be rejected'
        Assert ((Get-Code { Set-GangplankLazaretteSettings -Enabled $true -Path '//fileserver/share/arc' }) -eq 'BAD_REQUEST') 'Lazarette on a network share must be rejected (slashes)'
        [void](Set-GangplankLazaretteSettings -Enabled $true -Path $arc)
        Assert ((Get-GangplankConfiguredLazarettePath) -eq $arc) 'Configured Lazarette path not returned'
        Assert ((Find-GangplankLazaretteRoot) -eq [IO.Path]::GetFullPath($arc)) 'Configured Lazarette not found'
        [void](Set-GangplankLazaretteSettings -Enabled $false -Path $arc)
        Assert (-not (Test-GangplankLazaretteConfigured)) 'Disabling Lazarette must take effect'
        $env:GANGPLANK_LAZARETTE_PATH = $arc
        Assert (Test-GangplankLazaretteConfigured) 'GANGPLANK_LAZARETTE_PATH is the explicit environment opt-in'
        $env:GANGPLANK_LAZARETTE_PATH = $null

        # Credential store.
        if (Test-GangplankIsWindows) {
            Assert (Test-GangplankCredentialStoreAvailable) 'DPAPI should be available on Windows'
        } else {
            Assert (-not (Test-GangplankCredentialStoreAvailable)) 'Store must be unavailable without DPAPI'
            Assert ((Get-Code { Set-GangplankStoredCredential -Provider GitHub -Token 'ghp_example_value_123' }) -eq 'CREDENTIAL_STORE_UNAVAILABLE') 'Must refuse to store without DPAPI'
            $script:GangplankSecretProtector = @{
                Name = 'test protector'
                Protect = { param([byte[]]$b) [byte[]](@(0x4b) + @($b | ForEach-Object { $_ -bxor 0x5a })) }
                Unprotect = { param([byte[]]$b) if ($b[0] -ne 0x4b) { throw 'bad seal' }; [byte[]]@($b[1..($b.Length-1)] | ForEach-Object { $_ -bxor 0x5a }) }
            }
        }
        $token = 'ghp_FakeGangplankTestToken_' + [guid]::NewGuid().ToString('N')
        Assert ((Get-Code { Set-GangplankStoredCredential -Provider GitHub -Token 'has space in it' }) -eq 'BAD_REQUEST') 'Whitespace token rejected'
        Assert ((Get-Code { Set-GangplankStoredCredential -Provider GitHub -Token 'short' }) -eq 'BAD_REQUEST') 'Short token rejected'
        [void](Set-GangplankStoredCredential -Provider GitHub -Token $token)
        $file = [IO.File]::ReadAllText((Get-GangplankCredentialStorePath))
        Assert ($file -notmatch [regex]::Escape($token)) 'Token stored in clear text'
        Assert ($file -notmatch 'FakeGangplankTestToken') 'Token fragment stored in clear text'
        $resolved = Resolve-GangplankCredential -Provider GitHub
        Assert ($resolved.Value -eq $token -and $resolved.Source -eq 'stored') 'Stored token not resolved'
        Assert ((Get-GangplankToken -Provider GitHub) -eq $token) 'Get-GangplankToken must use the store'

        $status = Get-GangplankCredentialStatus
        $gh = @($status.credentials | Where-Object { $_.provider -eq 'GitHub' })[0]
        Assert ($gh.configured -and $gh.source -eq 'stored' -and $gh.storedAt) 'Status should show a stored GitHub token'
        Assert (($status | ConvertTo-Json -Depth 6) -notmatch 'FakeGangplankTestToken') 'Status leaked the token'
        Assert (-not $status.arc.enabled) 'Lazarette must show as disabled'

        $env:GITHUB_TOKEN = 'env-token-wins-1234'
        Assert ((Resolve-GangplankCredential -Provider GitHub).Source -eq 'environment') 'Environment should win over the store'
        $env:GITHUB_TOKEN = $null

        # A sealed value that fails to unseal (other account, copied file) is never used.
        $raw = Get-Content -LiteralPath (Get-GangplankCredentialStorePath) -Raw | ConvertFrom-Json
        $raw.Items.GitHub.Protected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not sealed'))
        [IO.File]::WriteAllText((Get-GangplankCredentialStorePath), ($raw | ConvertTo-Json -Depth 5))
        Assert ($null -eq (Get-GangplankStoredCredential -Provider GitHub)) 'Tampered store must not yield a token'
        $bad = @((Get-GangplankCredentialStatus).credentials | Where-Object { $_.provider -eq 'GitHub' })[0]
        Assert (-not $bad.configured -and $bad.storedUnreadable) 'An unreadable saved token must not be reported as ready'

        Assert (Remove-GangplankStoredCredential -Provider GitHub) 'Remove should report success'
        Assert ((Get-Code { Resolve-GangplankCredential -Provider GitHub }) -eq 'CREDENTIAL_MISSING') 'Removed token still resolved'
        Assert (-not (Test-Path -LiteralPath (Get-GangplankCredentialStorePath))) 'Empty store file should be deleted'

        # AI token uses the same chain.
        $env:GENAI_TOKEN = 'genai-env-token-1'
        Assert ((Get-GangplankAiToken) -eq 'genai-env-token-1') 'AI token should come from GENAI_TOKEN'
        $env:GENAI_TOKEN = $null
        Assert ($null -eq (Get-GangplankAiToken)) 'AI token must be null when unconfigured'

        # Audit: actions recorded, never values.
        $audit = [IO.File]::ReadAllText($script:GangplankAuditPath)
        Assert ($audit -match 'credential.saved' -and $audit -match 'credential.removed' -and $audit -match 'arc.settings') 'Audit entries missing'
        Assert ($audit -notmatch 'FakeGangplankTestToken') 'Audit leaked the token'
        Write-GangplankAudit -Action 'test' -Data @{ token = 'nope'; files = @('a') }
        Assert (((Get-GangplankAuditEntries -Last 1)[0].PSObject.Properties.Name) -notcontains 'token') 'Audit must drop token-like keys'
    } $temp
    Write-Host 'Credential store, opt-in Lazarette and audit checks passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
