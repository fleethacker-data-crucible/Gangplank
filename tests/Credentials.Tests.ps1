#Requires -Version 5.1
# Credential sources and opt-in ARC. Uses temp folders for the store, config and
# audit log. On Windows the real DPAPI protector is exercised; elsewhere a test
# protector is injected in-process (nothing outside the process can do that).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('keystone-cred-' + [guid]::NewGuid().ToString('N'))
$names = @('GITHUB_TOKEN','GITLAB_TOKEN','GENAI_TOKEN','KEYSTONE_AI_TOKEN','KEYSTONE_ARC_PATH','ARC_PATH','ARC_ROOT','ARC_HOME')
$saved = @{}
foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n,$null) }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    Import-Module (Join-Path $root 'Keystone.psm1') -Force -WarningAction SilentlyContinue
    & (Get-Module Keystone) {
        param($Temp)
        function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }
        function Get-Code([scriptblock]$Block) { try { & $Block; return '' } catch { return ([string]$_.Exception.Message -split '\|')[0] } }
        Initialize-KeystoneLogging -LogDir (Join-Path $Temp 'Logs') -Level ERROR
        Initialize-KeystoneConfig -ConfigPath (Join-Path $Temp 'config/keystone-config.json')
        $script:KeystoneCredentialStorePath = Join-Path $Temp 'store/credentials.json'
        $script:KeystoneAuditPath = Join-Path $Temp 'Logs/audit.jsonl'

        # Nothing configured: a clear, coded error.
        Assert ((Get-Code { Resolve-KeystoneCredential -Provider GitHub }) -eq 'CREDENTIAL_MISSING') 'Missing credential must be CREDENTIAL_MISSING'
        Assert ((Get-Code { Resolve-KeystoneCredential -Provider Jira }) -eq 'BAD_REQUEST') 'Unknown provider must be rejected'

        # ARC is never picked up from ARC_PATH or other tools' settings.
        $arc = Join-Path $Temp 'arc'
        [void](New-Item -ItemType Directory -Path (Join-Path $arc 'lib') -Force)
        [IO.File]::WriteAllText((Join-Path (Join-Path $arc 'lib') 'Arc.ps1'),'function Test-ArcVaultUnlocked { $false }')
        $env:ARC_PATH = $arc; $env:ARC_HOME = $arc
        Assert ($null -eq (Find-KeystoneArcRoot)) 'ARC_PATH must not enable ARC; it is opt-in'
        Assert (-not (Test-KeystoneArcConfigured)) 'ARC must start unconfigured'
        $init = Initialize-KeystoneArcAuthentication -Quiet
        Assert (-not $init.Configured -and -not $init.Loaded) 'Unconfigured ARC must not load or prompt'
        Assert ((Get-KeystoneArcConnectionStatus).code -eq 'ARC_NOT_CONFIGURED') 'Status must say ARC is not configured'
        $env:ARC_PATH = $null; $env:ARC_HOME = $null

        # ARC settings are validated and stored as a path only.
        Assert ((Get-Code { Set-KeystoneArcSettings -Enabled $true -Path '' }) -eq 'BAD_REQUEST') 'Enabling needs a path'
        Assert ((Get-Code { Set-KeystoneArcSettings -Enabled $true -Path 'relative\arc' }) -eq 'BAD_REQUEST') 'Relative path must be rejected'
        Assert ((Get-Code { Set-KeystoneArcSettings -Enabled $true -Path (Join-Path $Temp 'nowhere') }) -eq 'BAD_REQUEST') 'Folder without ARC must be rejected'
        Assert ((Get-Code { Set-KeystoneArcSettings -Enabled $true -Path '\\fileserver\share\arc' }) -eq 'BAD_REQUEST') 'ARC on a network share must be rejected'
        Assert ((Get-Code { Set-KeystoneArcSettings -Enabled $true -Path '//fileserver/share/arc' }) -eq 'BAD_REQUEST') 'ARC on a network share must be rejected (slashes)'
        [void](Set-KeystoneArcSettings -Enabled $true -Path $arc)
        Assert ((Get-KeystoneConfiguredArcPath) -eq $arc) 'Configured ARC path not returned'
        Assert ((Find-KeystoneArcRoot) -eq [IO.Path]::GetFullPath($arc)) 'Configured ARC not found'
        [void](Set-KeystoneArcSettings -Enabled $false -Path $arc)
        Assert (-not (Test-KeystoneArcConfigured)) 'Disabling ARC must take effect'
        $env:KEYSTONE_ARC_PATH = $arc
        Assert (Test-KeystoneArcConfigured) 'KEYSTONE_ARC_PATH is the explicit environment opt-in'
        $env:KEYSTONE_ARC_PATH = $null

        # Credential store.
        if (Test-KeystoneIsWindows) {
            Assert (Test-KeystoneCredentialStoreAvailable) 'DPAPI should be available on Windows'
        } else {
            Assert (-not (Test-KeystoneCredentialStoreAvailable)) 'Store must be unavailable without DPAPI'
            Assert ((Get-Code { Set-KeystoneStoredCredential -Provider GitHub -Token 'ghp_example_value_123' }) -eq 'CREDENTIAL_STORE_UNAVAILABLE') 'Must refuse to store without DPAPI'
            $script:KeystoneSecretProtector = @{
                Name = 'test protector'
                Protect = { param([byte[]]$b) [byte[]](@(0x4b) + @($b | ForEach-Object { $_ -bxor 0x5a })) }
                Unprotect = { param([byte[]]$b) if ($b[0] -ne 0x4b) { throw 'bad seal' }; [byte[]]@($b[1..($b.Length-1)] | ForEach-Object { $_ -bxor 0x5a }) }
            }
        }
        $token = 'ghp_FakeKeystoneTestToken_' + [guid]::NewGuid().ToString('N')
        Assert ((Get-Code { Set-KeystoneStoredCredential -Provider GitHub -Token 'has space in it' }) -eq 'BAD_REQUEST') 'Whitespace token rejected'
        Assert ((Get-Code { Set-KeystoneStoredCredential -Provider GitHub -Token 'short' }) -eq 'BAD_REQUEST') 'Short token rejected'
        [void](Set-KeystoneStoredCredential -Provider GitHub -Token $token)
        $file = [IO.File]::ReadAllText((Get-KeystoneCredentialStorePath))
        Assert ($file -notmatch [regex]::Escape($token)) 'Token stored in clear text'
        Assert ($file -notmatch 'FakeKeystoneTestToken') 'Token fragment stored in clear text'
        $resolved = Resolve-KeystoneCredential -Provider GitHub
        Assert ($resolved.Value -eq $token -and $resolved.Source -eq 'stored') 'Stored token not resolved'
        Assert ((Get-KeystoneToken -Provider GitHub) -eq $token) 'Get-KeystoneToken must use the store'

        $status = Get-KeystoneCredentialStatus
        $gh = @($status.credentials | Where-Object { $_.provider -eq 'GitHub' })[0]
        Assert ($gh.configured -and $gh.source -eq 'stored' -and $gh.storedAt) 'Status should show a stored GitHub token'
        Assert (($status | ConvertTo-Json -Depth 6) -notmatch 'FakeKeystoneTestToken') 'Status leaked the token'
        Assert (-not $status.arc.enabled) 'ARC must show as disabled'

        $env:GITHUB_TOKEN = 'env-token-wins-1234'
        Assert ((Resolve-KeystoneCredential -Provider GitHub).Source -eq 'environment') 'Environment should win over the store'
        $env:GITHUB_TOKEN = $null

        # A sealed value that fails to unseal (other account, copied file) is never used.
        $raw = Get-Content -LiteralPath (Get-KeystoneCredentialStorePath) -Raw | ConvertFrom-Json
        $raw.Items.GitHub.Protected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not sealed'))
        [IO.File]::WriteAllText((Get-KeystoneCredentialStorePath), ($raw | ConvertTo-Json -Depth 5))
        Assert ($null -eq (Get-KeystoneStoredCredential -Provider GitHub)) 'Tampered store must not yield a token'
        $bad = @((Get-KeystoneCredentialStatus).credentials | Where-Object { $_.provider -eq 'GitHub' })[0]
        Assert (-not $bad.configured -and $bad.storedUnreadable) 'An unreadable saved token must not be reported as ready'

        Assert (Remove-KeystoneStoredCredential -Provider GitHub) 'Remove should report success'
        Assert ((Get-Code { Resolve-KeystoneCredential -Provider GitHub }) -eq 'CREDENTIAL_MISSING') 'Removed token still resolved'
        Assert (-not (Test-Path -LiteralPath (Get-KeystoneCredentialStorePath))) 'Empty store file should be deleted'

        # AI token uses the same chain.
        $env:GENAI_TOKEN = 'genai-env-token-1'
        Assert ((Get-KeystoneAiToken) -eq 'genai-env-token-1') 'AI token should come from GENAI_TOKEN'
        $env:GENAI_TOKEN = $null
        Assert ($null -eq (Get-KeystoneAiToken)) 'AI token must be null when unconfigured'

        # Audit: actions recorded, never values.
        $audit = [IO.File]::ReadAllText($script:KeystoneAuditPath)
        Assert ($audit -match 'credential.saved' -and $audit -match 'credential.removed' -and $audit -match 'arc.settings') 'Audit entries missing'
        Assert ($audit -notmatch 'FakeKeystoneTestToken') 'Audit leaked the token'
        Write-KeystoneAudit -Action 'test' -Data @{ token = 'nope'; files = @('a') }
        Assert (((Get-KeystoneAuditEntries -Last 1)[0].PSObject.Properties.Name) -notcontains 'token') 'Audit must drop token-like keys'
    } $temp
    Write-Host 'Credential store, opt-in ARC and audit checks passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
