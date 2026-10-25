#Requires -Version 5.1
# ============================================================
#  Core/Credentials.ps1
#  Where provider tokens come from, in order:
#    1. Environment (GITHUB_TOKEN, GITLAB_TOKEN, GENAI_TOKEN / KEYSTONE_AI_TOKEN)
#    2. Keystone's local credential store: entered once in Integrations,
#       sealed with Windows DPAPI (CurrentUser) under %LOCALAPPDATA%\Keystone
#    3. ARC, only when explicitly configured (Arc.Enabled + Arc.Path in
#       config\keystone.local.json, or KEYSTONE_ARC_PATH). Keystone never
#       searches for ARC on its own.
#  Token values never go to the browser, the log or the audit trail.
# ============================================================

$script:KeystoneCredentialProviders = @('GitHub','GitLab','GenAi')
$script:KeystoneCredentialEnv = @{
    GitHub = @('GITHUB_TOKEN')
    GitLab = @('GITLAB_TOKEN')
    GenAi  = @('KEYSTONE_AI_TOKEN','GENAI_TOKEN','LLM_TOKEN','OPENAI_API_KEY')   # LLM_TOKEN/OPENAI_API_KEY: shared with Cascade
}
$script:KeystoneCredentialEntropy = [Text.Encoding]::UTF8.GetBytes('Keystone credential store v1')
$script:KeystoneCredentialStorePath = $null
# @{ Protect = { param([byte[]]$b) ... }; Unprotect = { ... }; Name = '...' } or $null.
# Default is Windows DPAPI; tests replace it in-process. Nothing outside the
# process (environment, files) can change it.
$script:KeystoneSecretProtector = $null

function Test-KeystoneIsWindows { return ($env:OS -eq 'Windows_NT') }

function Get-KeystoneDefaultSecretProtector {
    if (-not (Test-KeystoneIsWindows)) { return $null }
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { return $null }
    return @{
        Name = 'Windows DPAPI (current user)'
        Protect = {
            param([byte[]]$Bytes)
            return [System.Security.Cryptography.ProtectedData]::Protect($Bytes,$script:KeystoneCredentialEntropy,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        Unprotect = {
            param([byte[]]$Bytes)
            return [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes,$script:KeystoneCredentialEntropy,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
    }
}

function Get-KeystoneSecretProtector {
    if ($null -eq $script:KeystoneSecretProtector) { $script:KeystoneSecretProtector = Get-KeystoneDefaultSecretProtector }
    return $script:KeystoneSecretProtector
}

function Get-KeystoneCredentialStorePath {
    if ($script:KeystoneCredentialStorePath) { return $script:KeystoneCredentialStorePath }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = if ($env:HOME) { Join-Path $env:HOME '.local/share' } else { [IO.Path]::GetTempPath() }
    }
    return (Join-Path (Join-Path $base 'Keystone') 'credentials.json')
}

function Test-KeystoneCredentialStoreAvailable { return ($null -ne (Get-KeystoneSecretProtector)) }

function Read-KeystoneCredentialFile {
    $path = Get-KeystoneCredentialStorePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @{}
        if ($raw.Items) {
            foreach ($p in $raw.Items.PSObject.Properties) {
                if ($p.Name -in $script:KeystoneCredentialProviders -and $p.Value.Protected) {
                    $items[$p.Name] = @{ Protected = [string]$p.Value.Protected; Saved = [string]$p.Value.Saved }
                }
            }
        }
        return $items
    } catch {
        Write-KeystoneLog -Level WARN -Message 'Keystone credential store could not be read; treating it as empty.'
        return @{}
    }
}

function Write-KeystoneCredentialFile {
    param([hashtable]$Items)
    $path = Get-KeystoneCredentialStorePath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $doc = [ordered]@{ Version = 1; Protection = (Get-KeystoneSecretProtector).Name; Items = $Items }
    $tmp = Join-Path $dir ('credentials-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-KeystoneCredentialProvider {
    param([string]$Provider)
    if ($Provider -cnotin $script:KeystoneCredentialProviders) { throw 'BAD_REQUEST|Unsupported credential provider.' }
}

function Set-KeystoneStoredCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$Token)
    Assert-KeystoneCredentialProvider $Provider
    $value = $Token.Trim()
    if ($value.Length -lt 8 -or $value.Length -gt 512 -or $value -match '[\s\x00-\x1f\x7f]') {
        throw 'BAD_REQUEST|That does not look like an access token (8-512 characters, no spaces).'
    }
    $protector = Get-KeystoneSecretProtector
    if (-not $protector) { throw 'CREDENTIAL_STORE_UNAVAILABLE|Saving tokens needs Windows DPAPI. Use an environment variable instead.' }
    $sealed = & $protector.Protect ([Text.Encoding]::UTF8.GetBytes($value))
    $items = Read-KeystoneCredentialFile
    $items[$Provider] = @{ Protected = [Convert]::ToBase64String($sealed); Saved = (Get-Date).ToUniversalTime().ToString('o') }
    Write-KeystoneCredentialFile -Items $items
    Write-KeystoneAudit -Action 'credential.saved' -Data @{ provider = $Provider }
    return $true
}

function Remove-KeystoneStoredCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    Assert-KeystoneCredentialProvider $Provider
    $items = Read-KeystoneCredentialFile
    if (-not $items.ContainsKey($Provider)) { return $false }
    [void]$items.Remove($Provider)
    if ($items.Count -eq 0) {
        Remove-Item -LiteralPath (Get-KeystoneCredentialStorePath) -Force -ErrorAction SilentlyContinue
    } else {
        Write-KeystoneCredentialFile -Items $items
    }
    Write-KeystoneAudit -Action 'credential.removed' -Data @{ provider = $Provider }
    return $true
}

function Get-KeystoneStoredCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    Assert-KeystoneCredentialProvider $Provider
    $items = Read-KeystoneCredentialFile
    if (-not $items.ContainsKey($Provider)) { return $null }
    $protector = Get-KeystoneSecretProtector
    if (-not $protector) { return $null }
    try {
        $plain = & $protector.Unprotect ([Convert]::FromBase64String($items[$Provider].Protected))
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {
        # Another Windows account, a copied file, or tampering: unreadable, never guessed.
        Write-KeystoneLog -Level WARN -Message "Stored $Provider credential could not be unsealed for this Windows account."
        return $null
    }
}

function Get-KeystoneEnvironmentCredential {
    param([string]$Provider)
    foreach ($name in $script:KeystoneCredentialEnv[$Provider]) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return [pscustomobject]@{ Name = $name; Value = $v.Trim() } }
    }
    return $null
}

# ---------------------------------------------------------------------------
# ARC: opt-in only
# ---------------------------------------------------------------------------
function Get-KeystoneLocalSettingsPath {
    if (-not $script:KeystoneConfigPath) { Initialize-KeystoneConfig }
    return (Join-Path (Split-Path $script:KeystoneConfigPath -Parent) 'keystone.local.json')
}

function Get-KeystoneLocalSettings {
    # Per-workstation, non-secret settings (config\keystone.local.json, not committed).
    $path = Get-KeystoneLocalSettingsPath
    $settings = [ordered]@{
        Arc = [ordered]@{ Enabled = $false; Path = '' }
        Workspaces = [ordered]@{ Root = '' }
        Intelligence = [ordered]@{ Endpoint = ''; Profile = ''; Model = ''; ChatUrl = ''; Auth = '' }
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw.Arc) {
                $settings.Arc.Enabled = ($raw.Arc.Enabled -eq $true)
                if ($raw.Arc.Path -is [string]) { $settings.Arc.Path = $raw.Arc.Path }
            }
            if ($raw.Workspaces -and $raw.Workspaces.Root -is [string]) { $settings.Workspaces.Root = $raw.Workspaces.Root }
            if ($raw.Intelligence) {
                foreach ($k in @('Endpoint','Profile','Model','ChatUrl','Auth')) {
                    $v = $raw.Intelligence.PSObject.Properties[$k]
                    if ($v -and $v.Value -is [string]) { $settings.Intelligence[$k] = $v.Value }
                }
            }
        } catch { Write-KeystoneLog -Level WARN -Message 'keystone.local.json could not be read; using defaults (ARC off).' }
    }
    return $settings
}

function Save-KeystoneLocalSettings {
    param([Parameter(Mandatory)]$Settings)
    $path = Get-KeystoneLocalSettingsPath
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($Settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-KeystoneLocalFolderPath {
    # A full, local folder path (no network shares, no control characters).
    param([string]$Path,[string]$What)
    $clean = ([string]$Path).Trim().Trim('"')
    if (-not $clean -or $clean.Length -gt 400 -or $clean -match '[\x00-\x1f]') { throw "BAD_REQUEST|Enter the full $What path." }
    if (-not [IO.Path]::IsPathRooted($clean)) { throw "BAD_REQUEST|Enter the full $What path, for example C:\Users\you\Keystone." }
    if ($clean -match '^(\\\\|//)') { throw "BAD_REQUEST|The $What must be on this PC, not a network share." }
    return $clean
}

function Get-KeystoneDefaultWorkspaceRoot {
    # Like a normal clone location: a "Keystone" folder in the user's home, outside the tool.
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [IO.Path]::GetTempPath() }
    return (Join-Path $homeDir 'Keystone')
}

function Get-KeystoneWorkspaceRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:KEYSTONE_WORK_ROOT)) { return $env:KEYSTONE_WORK_ROOT.Trim().Trim('"') }
    $configured = [string](Get-KeystoneLocalSettings).Workspaces.Root
    if ($configured) { return $configured }
    return (Get-KeystoneDefaultWorkspaceRoot)
}

function Set-KeystoneWorkspaceRoot {
    [CmdletBinding()]
    param([string]$Path)
    $settings = Get-KeystoneLocalSettings
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $settings.Workspaces.Root = ''
    } else {
        $clean = Assert-KeystoneLocalFolderPath -Path $Path -What 'workspace folder'
        $full = [IO.Path]::GetFullPath($clean)
        $toolRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
        if ($full.StartsWith($toolRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\','/') -ieq $toolRoot) {
            throw 'BAD_REQUEST|Choose a folder outside the Keystone program folder, so your work is never mixed with the tool.'
        }
        if (-not (Test-Path -LiteralPath $full)) { [void](New-Item -ItemType Directory -Path $full -Force) }
        $settings.Workspaces.Root = $full
    }
    Save-KeystoneLocalSettings -Settings $settings
    Write-KeystoneAudit -Action 'workspace.root' -Data @{ root = $(if ($settings.Workspaces.Root) { $settings.Workspaces.Root } else { '(default)' }) }
    return (Get-KeystoneWorkspaceRoot)
}

function Set-KeystoneArcSettings {
    [CmdletBinding()]
    param([bool]$Enabled,[string]$Path = '')
    $clean = ([string]$Path).Trim().Trim('"')
    if ($clean.Length -gt 400 -or $clean -match '[\x00-\x1f]') { throw 'BAD_REQUEST|ARC folder path is not valid.' }
    if ($Enabled) {
        if (-not $clean) { throw 'BAD_REQUEST|Enter the ARC folder path to enable ARC.' }
        if (-not [IO.Path]::IsPathRooted($clean)) { throw 'BAD_REQUEST|Enter the full ARC folder path, for example C:\Users\you\Projects\arc.' }
        # Local folders only: ARC code is loaded at startup, never from a network share.
        if ($clean -match '^(\\\\|//)') { throw 'BAD_REQUEST|ARC must be in a local folder, not a network share.' }
        if (-not (Get-KeystoneArcFlavor -ArcRoot $clean)) { throw 'BAD_REQUEST|No ARC installation found there (expected lib\Arc.ps1).' }
    }
    $settings = Get-KeystoneLocalSettings
    $settings.Arc.Enabled = [bool]$Enabled
    $settings.Arc.Path = $clean
    Save-KeystoneLocalSettings -Settings $settings
    Write-KeystoneAudit -Action 'arc.settings' -Data @{ enabled = [bool]$Enabled }
    return $settings
}

function Get-KeystoneConfiguredArcPath {
    # The only ways ARC gets used: KEYSTONE_ARC_PATH, or Arc.Enabled + Arc.Path.
    if (-not [string]::IsNullOrWhiteSpace($env:KEYSTONE_ARC_PATH)) { return $env:KEYSTONE_ARC_PATH.Trim().Trim('"') }
    $settings = Get-KeystoneLocalSettings
    if ($settings.Arc.Enabled -and $settings.Arc.Path) { return [string]$settings.Arc.Path }
    return $null
}

function Test-KeystoneArcConfigured { return [bool](Get-KeystoneConfiguredArcPath) }

# ---------------------------------------------------------------------------
# Resolution and status
# ---------------------------------------------------------------------------
function Resolve-KeystoneCredential {
    # Returns @{ Value; Source } or throws a coded error the UI can explain.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    Assert-KeystoneCredentialProvider $Provider
    $fromEnv = Get-KeystoneEnvironmentCredential -Provider $Provider
    if ($fromEnv) { return [pscustomobject]@{ Value = $fromEnv.Value; Source = 'environment' } }
    $stored = Get-KeystoneStoredCredential -Provider $Provider
    if ($stored) { return [pscustomobject]@{ Value = $stored; Source = 'stored' } }
    if (Test-KeystoneArcConfigured) {
        $token = Get-KeystoneArcCredential -Provider $Provider
        if ($token) { return [pscustomobject]@{ Value = $token; Source = 'arc' } }
    }
    $envName = $script:KeystoneCredentialEnv[$Provider][0]
    throw "CREDENTIAL_MISSING|No $Provider token is configured. Add one in Integrations or set $envName before starting Keystone."
}

function Get-KeystoneCredentialStatus {
    $arcOn = Test-KeystoneArcConfigured
    $arcStatus = if ($arcOn) { Get-KeystoneArcConnectionStatus } else { $null }
    $stored = Read-KeystoneCredentialFile
    $rows = foreach ($p in $script:KeystoneCredentialProviders) {
        $env = Get-KeystoneEnvironmentCredential -Provider $p
        $arcItem = $null
        $arcReady = $false
        if ($arcOn) {
            $arcItem = Get-KeystoneArcItemName -Provider $p
            $arcReady = [bool]($arcStatus.arcUnlocked -and (@($arcStatus.itemNames) -contains $arcItem))
        }
        # A saved entry that cannot be unsealed (other account, damaged file) is not "ready".
        $storedOk = ($stored.ContainsKey($p) -and $null -ne (Get-KeystoneStoredCredential -Provider $p))
        $source = if ($env) { 'environment' } elseif ($storedOk) { 'stored' } elseif ($arcReady) { 'arc' } else { 'none' }
        [pscustomobject]@{
            provider = $p
            configured = ($source -ne 'none')
            source = $source
            environmentVariable = $(if ($env) { $env.Name } else { $script:KeystoneCredentialEnv[$p][0] })
            storedAt = $(if ($stored.ContainsKey($p)) { $stored[$p].Saved } else { '' })
            storedUnreadable = ($stored.ContainsKey($p) -and -not $storedOk)
            arcItem = $(if ($arcItem) { $arcItem } else { '' })
            arcItemFound = $arcReady
        }
    }
    $settings = Get-KeystoneLocalSettings
    return [pscustomobject]@{
        credentials = @($rows)
        storeAvailable = (Test-KeystoneCredentialStoreAvailable)
        storeProtection = $(if (Test-KeystoneCredentialStoreAvailable) { (Get-KeystoneSecretProtector).Name } else { '' })
        arc = [pscustomobject]@{
            enabled = [bool]$arcOn
            configuredPath = $(if ($env:KEYSTONE_ARC_PATH) { $env:KEYSTONE_ARC_PATH } else { [string]$settings.Arc.Path })
            fromEnvironment = (-not [string]::IsNullOrWhiteSpace($env:KEYSTONE_ARC_PATH))
            status = $arcStatus
        }
    }
}
