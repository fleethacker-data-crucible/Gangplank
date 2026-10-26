#Requires -Version 5.1
# ============================================================
#  Core/Credentials.ps1
#  Where provider tokens come from, in order:
#    1. Environment (GITHUB_TOKEN, GITLAB_TOKEN, GANGPLANK_AI_TOKEN; legacy names in Configuration.ps1)
#    2. Gangplank's local credential store: entered once in Integrations,
#       sealed with Windows DPAPI (CurrentUser) under %LOCALAPPDATA%\Gangplank
#    3. Lazarette, only when explicitly configured (Lazarette.Enabled + .Path in
#       config\gangplank.local.json, or GANGPLANK_LAZARETTE_PATH). Gangplank never
#       searches for Lazarette on its own.
#  Token values never go to the browser, the log or the audit trail.
# ============================================================

$script:GangplankCredentialProviders = @('GitHub','GitLab','AI')
$script:GangplankCredentialEnv = @{
    GitHub = @('GITHUB_TOKEN')
    GitLab = @('GITLAB_TOKEN')
    # LLM_TOKEN/OPENAI_API_KEY: shared with Halyard; the legacy variable keeps its former precedence.
    AI     = @('GANGPLANK_AI_TOKEN') + @($script:GangplankLegacyAliases.TokenEnv['AI']) + @('LLM_TOKEN','OPENAI_API_KEY')
}
$script:GangplankCredentialEntropy = [Text.Encoding]::UTF8.GetBytes('Keystone credential store v1')
$script:GangplankCredentialStorePath = $null
# @{ Protect = { param([byte[]]$b) ... }; Unprotect = { ... }; Name = '...' } or $null.
# Default is Windows DPAPI; tests replace it in-process. Nothing outside the
# process (environment, files) can change it.
$script:GangplankSecretProtector = $null

function Test-GangplankIsWindows { return ($env:OS -eq 'Windows_NT') }

function Get-GangplankDefaultSecretProtector {
    if (-not (Test-GangplankIsWindows)) { return $null }
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { return $null }
    return @{
        Name = 'Windows DPAPI (current user)'
        Protect = {
            param([byte[]]$Bytes)
            return [System.Security.Cryptography.ProtectedData]::Protect($Bytes,$script:GangplankCredentialEntropy,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        Unprotect = {
            param([byte[]]$Bytes)
            return [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes,$script:GangplankCredentialEntropy,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
    }
}

function Get-GangplankSecretProtector {
    if ($null -eq $script:GangplankSecretProtector) { $script:GangplankSecretProtector = Get-GangplankDefaultSecretProtector }
    return $script:GangplankSecretProtector
}

function Get-GangplankCredentialStorePath {
    if ($script:GangplankCredentialStorePath) { return $script:GangplankCredentialStorePath }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = if ($env:HOME) { Join-Path $env:HOME '.local/share' } else { [IO.Path]::GetTempPath() }
    }
    return (Join-Path (Join-Path $base 'Gangplank') 'credentials.json')
}

function Test-GangplankCredentialStoreAvailable { return ($null -ne (Get-GangplankSecretProtector)) }

function Read-GangplankCredentialFile {
    $path = Get-GangplankCredentialStorePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @{}
        if ($raw.Items) {
            foreach ($p in $raw.Items.PSObject.Properties) {
                $name = Resolve-GangplankPurposeName $p.Name -Strict   # an entry saved under a legacy name is read as the current one
                if ($name -in $script:GangplankCredentialProviders -and $p.Value.Protected -and -not ($items.ContainsKey($name) -and $p.Name -cne $name)) {
                    $items[$name] = @{ Protected = [string]$p.Value.Protected; Saved = [string]$p.Value.Saved }
                }
            }
        }
        return $items
    } catch {
        Write-GangplankLog -Level WARN -Message 'Gangplank credential store could not be read; treating it as empty.'
        return @{}
    }
}

function Write-GangplankCredentialFile {
    param([hashtable]$Items)
    $path = Get-GangplankCredentialStorePath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $doc = [ordered]@{ Version = 1; Protection = (Get-GangplankSecretProtector).Name; Items = $Items }
    $tmp = Join-Path $dir ('credentials-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-GangplankCredentialProvider {
    param([string]$Provider)
    if ($Provider -cnotin $script:GangplankCredentialProviders) { throw 'BAD_REQUEST|Unsupported credential provider.' }
}

function Set-GangplankStoredCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$Token)
    $Provider = Resolve-GangplankPurposeName $Provider -Strict
    Assert-GangplankCredentialProvider $Provider
    $value = $Token.Trim()
    if ($value.Length -lt 8 -or $value.Length -gt 512 -or $value -match '[\s\x00-\x1f\x7f]') {
        throw 'BAD_REQUEST|That does not look like an access token (8-512 characters, no spaces).'
    }
    $protector = Get-GangplankSecretProtector
    if (-not $protector) { throw 'CREDENTIAL_STORE_UNAVAILABLE|Saving tokens needs Windows DPAPI. Use an environment variable instead.' }
    $sealed = & $protector.Protect ([Text.Encoding]::UTF8.GetBytes($value))
    $items = Read-GangplankCredentialFile
    $items[$Provider] = @{ Protected = [Convert]::ToBase64String($sealed); Saved = (Get-Date).ToUniversalTime().ToString('o') }
    Write-GangplankCredentialFile -Items $items
    Write-GangplankAudit -Action 'credential.saved' -Data @{ provider = $Provider }
    return $true
}

function Remove-GangplankStoredCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    $Provider = Resolve-GangplankPurposeName $Provider -Strict
    Assert-GangplankCredentialProvider $Provider
    $items = Read-GangplankCredentialFile
    if (-not $items.ContainsKey($Provider)) { return $false }
    [void]$items.Remove($Provider)
    if ($items.Count -eq 0) {
        Remove-Item -LiteralPath (Get-GangplankCredentialStorePath) -Force -ErrorAction SilentlyContinue
    } else {
        Write-GangplankCredentialFile -Items $items
    }
    Write-GangplankAudit -Action 'credential.removed' -Data @{ provider = $Provider }
    return $true
}

function Get-GangplankStoredCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    $Provider = Resolve-GangplankPurposeName $Provider -Strict
    Assert-GangplankCredentialProvider $Provider
    $items = Read-GangplankCredentialFile
    if (-not $items.ContainsKey($Provider)) { return $null }
    $protector = Get-GangplankSecretProtector
    if (-not $protector) { return $null }
    try {
        $plain = & $protector.Unprotect ([Convert]::FromBase64String($items[$Provider].Protected))
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {
        # Another Windows account, a copied file, or tampering: unreadable, never guessed.
        Write-GangplankLog -Level WARN -Message "Stored $Provider credential could not be unsealed for this Windows account."
        return $null
    }
}

function Get-GangplankEnvironmentCredential {
    param([string]$Provider)
    $Provider = Resolve-GangplankPurposeName $Provider -Strict
    foreach ($name in $script:GangplankCredentialEnv[$Provider]) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return [pscustomobject]@{ Name = $name; Value = $v.Trim() } }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Lazarette: opt-in only
# ---------------------------------------------------------------------------
function Get-GangplankLocalSettingsPath {
    if (-not $script:GangplankConfigPath) { Initialize-GangplankConfig }
    # Copied forward once from keystone.local.json by Initialize-GangplankConfig.
    return (Join-Path (Split-Path $script:GangplankConfigPath -Parent) 'gangplank.local.json')
}

function Get-GangplankLocalSettings {
    # Per-workstation, non-secret settings (config\gangplank.local.json, not committed).
    $path = Get-GangplankLocalSettingsPath
    $settings = [ordered]@{
        Lazarette = [ordered]@{ Enabled = $false; Path = '' }
        Workspaces = [ordered]@{ Root = '' }
        Intelligence = [ordered]@{ Endpoint = ''; Profile = ''; Model = ''; ChatUrl = ''; Auth = '' }
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            # "Arc" is the key a pre-rename keystone.local.json used.
            $laz = $null
            foreach ($key in @('Lazarette','Arc')) { if ($raw.PSObject.Properties[$key] -and $raw.$key) { $laz = $raw.$key; break } }
            if ($laz) {
                $settings.Lazarette.Enabled = ($laz.Enabled -eq $true)
                if ($laz.Path -is [string]) { $settings.Lazarette.Path = $laz.Path }
            }
            if ($raw.Workspaces -and $raw.Workspaces.Root -is [string]) { $settings.Workspaces.Root = $raw.Workspaces.Root }
            if ($raw.Intelligence) {
                foreach ($k in @('Endpoint','Profile','Model','ChatUrl','Auth')) {
                    $v = $raw.Intelligence.PSObject.Properties[$k]
                    if ($v -and $v.Value -is [string]) { $settings.Intelligence[$k] = $v.Value }
                }
            }
        } catch { Write-GangplankLog -Level WARN -Message 'gangplank.local.json could not be read; using defaults (Lazarette off).' }
    }
    return $settings
}

function Save-GangplankLocalSettings {
    param([Parameter(Mandatory)]$Settings)
    $path = Get-GangplankLocalSettingsPath
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($Settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-GangplankLocalFolderPath {
    # A full, local folder path (no network shares, no control characters).
    param([string]$Path,[string]$What)
    $clean = ([string]$Path).Trim().Trim('"')
    if (-not $clean -or $clean.Length -gt 400 -or $clean -match '[\x00-\x1f]') { throw "BAD_REQUEST|Enter the full $What path." }
    if (-not [IO.Path]::IsPathRooted($clean)) { throw "BAD_REQUEST|Enter the full $What path, for example C:\Users\you\Gangplank." }
    if ($clean -match '^(\\\\|//)') { throw "BAD_REQUEST|The $What must be on this PC, not a network share." }
    return $clean
}

function Get-GangplankDefaultWorkspaceRoot {
    # Like a normal clone location: a "Gangplank" folder in the user's home, outside the tool.
    # A user who already has workspaces in the Keystone-era default (<home>\Keystone) and no
    # Gangplank folder keeps using it: workspaces hold unsaved edits and the saved session
    # points into them, so they are never moved or copied.
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [IO.Path]::GetTempPath() }
    $current = Join-Path $homeDir 'Gangplank'
    $legacy = Join-Path $homeDir 'Keystone'
    if (-not (Test-Path -LiteralPath $current) -and (Test-Path -LiteralPath $legacy -PathType Container)) { return $legacy }
    return $current
}

function Get-GangplankWorkspaceRoot {
    if (-not [string]::IsNullOrWhiteSpace((Get-GangplankEnv WORK_ROOT))) { return (Get-GangplankEnv WORK_ROOT).Trim().Trim('"') }
    $configured = [string](Get-GangplankLocalSettings).Workspaces.Root
    if ($configured) { return $configured }
    return (Get-GangplankDefaultWorkspaceRoot)
}

function Set-GangplankWorkspaceRoot {
    [CmdletBinding()]
    param([string]$Path)
    $settings = Get-GangplankLocalSettings
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $settings.Workspaces.Root = ''
    } else {
        $clean = Assert-GangplankLocalFolderPath -Path $Path -What 'workspace folder'
        $full = [IO.Path]::GetFullPath($clean)
        $toolRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
        if ($full.StartsWith($toolRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\','/') -ieq $toolRoot) {
            throw 'BAD_REQUEST|Choose a folder outside the Gangplank program folder, so your work is never mixed with the tool.'
        }
        if (-not (Test-Path -LiteralPath $full)) { [void](New-Item -ItemType Directory -Path $full -Force) }
        $settings.Workspaces.Root = $full
    }
    Save-GangplankLocalSettings -Settings $settings
    Write-GangplankAudit -Action 'workspace.root' -Data @{ root = $(if ($settings.Workspaces.Root) { $settings.Workspaces.Root } else { '(default)' }) }
    return (Get-GangplankWorkspaceRoot)
}

function Set-GangplankLazaretteSettings {
    [CmdletBinding()]
    param([bool]$Enabled,[string]$Path = '')
    $clean = ([string]$Path).Trim().Trim('"')
    if ($clean.Length -gt 400 -or $clean -match '[\x00-\x1f]') { throw 'BAD_REQUEST|Lazarette folder path is not valid.' }
    if ($Enabled) {
        if (-not $clean) { throw 'BAD_REQUEST|Enter the Lazarette folder path to enable Lazarette.' }
        if (-not [IO.Path]::IsPathRooted($clean)) { throw 'BAD_REQUEST|Enter the full Lazarette folder path, for example C:\Users\you\Projects\Lazarette.' }
        # Local folders only: Lazarette code is loaded at startup, never from a network share.
        if ($clean -match '^(\\\\|//)') { throw 'BAD_REQUEST|Lazarette must be in a local folder, not a network share.' }
        if (-not (Get-GangplankLazaretteFlavor -LazaretteRoot $clean)) { throw 'BAD_REQUEST|No Lazarette installation found there (expected lib\Lazarette.ps1 or lib\Arc.ps1).' }
    }
    $settings = Get-GangplankLocalSettings
    $settings.Lazarette.Enabled = [bool]$Enabled
    $settings.Lazarette.Path = $clean
    Save-GangplankLocalSettings -Settings $settings
    # Was 'arc.settings' before the rename; older entries in Logs\audit.jsonl keep that name.
    Write-GangplankAudit -Action 'lazarette.settings' -Data @{ enabled = [bool]$Enabled }
    return $settings
}

function Get-GangplankConfiguredLazarettePath {
    # The only ways Lazarette gets used: GANGPLANK_LAZARETTE_PATH (formerly
    # KEYSTONE_ARC_PATH, still read), or Lazarette.Enabled + Lazarette.Path in gangplank.local.json.
    $fromEnv = Get-GangplankLazarettePathEnv
    if ($fromEnv) { return $fromEnv }
    $settings = Get-GangplankLocalSettings
    if ($settings.Lazarette.Enabled -and $settings.Lazarette.Path) { return [string]$settings.Lazarette.Path }
    return $null
}

function Get-GangplankLazarettePathEnv {
    # Explicit environment opt-in: GANGPLANK_LAZARETTE_PATH, then the pre-rename
    # KEYSTONE_ARC_PATH. Generic LAZARETTE_PATH / ARC_PATH are
    # deliberately not read: Lazarette is opt-in per app.
    foreach ($n in @('GANGPLANK_LAZARETTE_PATH','KEYSTONE_ARC_PATH')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim().Trim('"') }
    }
    return $null
}

function Test-GangplankLazaretteConfigured { return [bool](Get-GangplankConfiguredLazarettePath) }

# ---------------------------------------------------------------------------
# Resolution and status
# ---------------------------------------------------------------------------
function Resolve-GangplankCredential {
    # Returns @{ Value; Source } or throws a coded error the UI can explain.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    $Provider = Resolve-GangplankPurposeName $Provider -Strict
    Assert-GangplankCredentialProvider $Provider
    $fromEnv = Get-GangplankEnvironmentCredential -Provider $Provider
    if ($fromEnv) { return [pscustomobject]@{ Value = $fromEnv.Value; Source = 'environment' } }
    $stored = Get-GangplankStoredCredential -Provider $Provider
    if ($stored) { return [pscustomobject]@{ Value = $stored; Source = 'stored' } }
    if (Test-GangplankLazaretteConfigured) {
        $token = Get-GangplankLazaretteCredential -Provider $Provider
        if ($token) { return [pscustomobject]@{ Value = $token; Source = 'lazarette' } }
    }
    $envName = $script:GangplankCredentialEnv[$Provider][0]
    throw "CREDENTIAL_MISSING|No $Provider token is configured. Add one in Integrations or set $envName before starting Gangplank."
}

function Get-GangplankCredentialStatus {
    $lazaretteOn = Test-GangplankLazaretteConfigured
    $lazaretteStatus = if ($lazaretteOn) { Get-GangplankLazaretteConnectionStatus } else { $null }
    $stored = Read-GangplankCredentialFile
    $rows = foreach ($p in $script:GangplankCredentialProviders) {
        $env = Get-GangplankEnvironmentCredential -Provider $p
        $lazaretteItem = $null
        $lazaretteReady = $false
        if ($lazaretteOn) {
            $lazaretteItem = Get-GangplankLazaretteItemName -Provider $p
            if ($lazaretteStatus.lazaretteUnlocked) { $lazaretteItem = Resolve-GangplankLazaretteItemInCatalog -Provider $p -Name $lazaretteItem -Catalog @($lazaretteStatus.itemNames) }
            $lazaretteReady = [bool]($lazaretteStatus.lazaretteUnlocked -and (@($lazaretteStatus.itemNames) -contains $lazaretteItem))
        }
        # A saved entry that cannot be unsealed (other account, damaged file) is not "ready".
        $storedOk = ($stored.ContainsKey($p) -and $null -ne (Get-GangplankStoredCredential -Provider $p))
        $source = if ($env) { 'environment' } elseif ($storedOk) { 'stored' } elseif ($lazaretteReady) { 'lazarette' } else { 'none' }
        [pscustomobject]@{
            provider = $p
            configured = ($source -ne 'none')
            source = $source
            environmentVariable = $(if ($env) { $env.Name } else { $script:GangplankCredentialEnv[$p][0] })
            storedAt = $(if ($stored.ContainsKey($p)) { $stored[$p].Saved } else { '' })
            storedUnreadable = ($stored.ContainsKey($p) -and -not $storedOk)
            lazaretteItem = $(if ($lazaretteItem) { $lazaretteItem } else { '' })
            lazaretteItemFound = $lazaretteReady
        }
    }
    $settings = Get-GangplankLocalSettings
    return [pscustomobject]@{
        credentials = @($rows)
        storeAvailable = (Test-GangplankCredentialStoreAvailable)
        storeProtection = $(if (Test-GangplankCredentialStoreAvailable) { (Get-GangplankSecretProtector).Name } else { '' })
        lazarette = [pscustomobject]@{
            enabled = [bool]$lazaretteOn
            configuredPath = $(if (Get-GangplankLazarettePathEnv) { Get-GangplankLazarettePathEnv } else { [string]$settings.Lazarette.Path })
            fromEnvironment = [bool](Get-GangplankLazarettePathEnv)
            status = $lazaretteStatus
        }
    }
}
