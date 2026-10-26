#Requires -Version 5.1
# ============================================================
#  Core/Configuration.ps1
#  Lazarette Service name resolution (names only - never secrets)
# ============================================================
#
# Canonical Lazarette Service names (hard-coded fallbacks only):
#   gitlab            - GitLab PAT (your organization's GitLab host)
#   github            - GitHub token
#   ai-api-key        - AI endpoint token (purpose AI)
#   data-platform-api - enterprise data platform token (purpose DataPlatform; reserved)
# Names and values from earlier releases are accepted through the legacy alias
# block below and are never written.
#
# Resolution order for GitLab / GitHub:
#   1. Env GANGPLANK_LAZARETTE_ITEM_<Purpose>, then KEYSTONE_ARC_ITEM_ /
#      LAZARETTE_ITEM_ / ARC_ITEM_ / HALYARD_LAZARETTE_ITEM_<Purpose>, then legacy prefixes
#      (legacy alias block below)
#   (Item names are data in the user's vault: Gangplank never renames them.)
#   2. config\lazarette-items.local.json (per-workstation picker mapping)
#   3. config LazaretteItems.<Purpose> (ArcItems in a pre-rename config file)
#   4. Canonical hard-coded name
# ============================================================

$script:GangplankConfigPath = $null

# Canonical fallbacks - exact Lazarette Service names
$script:GangplankLazaretteCanonical = @{
    GitLab       = "gitlab"
    GitHub       = "github"
    AI           = "ai-api-key"
    DataPlatform = "data-platform-api"
}
$script:GangplankLazarettePurposes = @('GitHub','GitLab','AI','DataPlatform')

# Legacy aliases: names and values earlier releases used. They are ACCEPTED on input
# (environment, config files, the credential store, the API, vault item lookup) so
# existing setups keep working, and are never written. Keep every legacy literal here.
$script:GangplankLegacyAliases = @{
    Purpose    = @{ 'GenAi' = 'AI'; 'Advana' = 'DataPlatform' }                            # legacy alias: purpose names
    ItemName   = @{ GitLab = 'gitmil'; AI = 'genapi'; DataPlatform = 'advana-api' }       # legacy alias: default vault item names
    TokenEnv   = @{ AI = @('GENAI_TOKEN') }                                                 # legacy alias: AI token variable
    ItemEnvPrefix = @('CASCADE_ARC_ITEM_')                                                  # legacy alias: sibling tool's former item variable prefix
}

function Resolve-GangplankPurposeName {
    # Current purpose name for a purpose or a legacy alias; anything else unchanged.
    # Case-insensitive by default; -Strict matches the exact spelling only (credential provider checks).
    param([AllowNull()][AllowEmptyString()][string]$Name,[switch]$Strict)
    $n = ([string]$Name).Trim()
    foreach ($k in $script:GangplankLegacyAliases.Purpose.Keys) {
        if (($Strict -and $k -ceq $n) -or (-not $Strict -and $k -ieq $n)) { return $script:GangplankLegacyAliases.Purpose[$k] }
    }
    if ($Strict) { return $n }
    foreach ($k in $script:GangplankLazarettePurposes) { if ($k -ieq $n) { return $k } }
    return $n
}

function Get-GangplankLegacyPurposeNames {
    # Legacy aliases of a current purpose name (for environment variable names).
    param([string]$Purpose)
    return @($script:GangplankLegacyAliases.Purpose.Keys | Where-Object { $script:GangplankLegacyAliases.Purpose[$_] -eq $Purpose })
}

function Get-GangplankLegacyItemName {
    # The item name earlier releases used by default for a purpose, or $null.
    param([string]$Purpose)
    if ($script:GangplankLegacyAliases.ItemName.ContainsKey($Purpose)) { return [string]$script:GangplankLegacyAliases.ItemName[$Purpose] }
    return $null
}

function Get-GangplankGitLabHost {
    # Your organization's GitLab host: GANGPLANK_GITLAB_HOST, else config GitLabHost, else '' (none).
    # A full URL is accepted; only its host is used. A bare host may contain only letters,
    # digits, dots and hyphens.
    $v = Get-GangplankEnv GITLAB_HOST
    if (-not $v) {
        try { $cfg = Get-GangplankConfig; $p = $cfg.PSObject.Properties['GitLabHost']; if ($p -and $p.Value) { $v = [string]$p.Value } } catch { }
    }
    $v = ([string]$v).Trim()
    if (-not $v) { return '' }
    $u = $null
    if ($v -match '://') {
        if ([uri]::TryCreate($v,[UriKind]::Absolute,[ref]$u) -and $u.Host) { return $u.Host.ToLowerInvariant() }
        throw "GitLab host setting is not a valid URL. Set GANGPLANK_GITLAB_HOST (or GitLabHost in config\gangplank-config.json) to a host name such as gitlab.example.org."
    }
    $h = $v.TrimEnd('/')
    if ($h -cnotmatch '^[A-Za-z0-9.-]+$') {
        throw "GitLab host setting may contain only letters, digits, dots and hyphens (for example gitlab.example.org). Check GANGPLANK_GITLAB_HOST or GitLabHost in config\gangplank-config.json."
    }
    return $h.ToLowerInvariant()
}

function Get-GangplankTrustedGitLabHosts {
    # No GitLab host is trusted by default. Only the host the user configured
    # (GANGPLANK_GITLAB_HOST / config GitLabHost) and administrator-approved
    # GANGPLANK_GITLAB_ALLOWED_HOSTS are trusted.
    $hosts = @()
    $configured = Get-GangplankGitLabHost
    if ($configured) { $hosts += $configured }
    if ((Get-GangplankEnv GITLAB_ALLOWED_HOSTS)) {
        $hosts += @((Get-GangplankEnv GITLAB_ALLOWED_HOSTS) -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    return @($hosts | Select-Object -Unique)
}

# Config files that had Keystone/ARC names before the rename. Each pair is
# (pre-rename name, current name), in the same config folder.
$script:GangplankLegacyConfigFiles = @(
    @('keystone-config.json','gangplank-config.json'),
    @('keystone.local.json','gangplank.local.json'),
    @('arc-items.local.json','lazarette-items.local.json')
)

function Copy-GangplankLegacyConfigFiles {
    <#
      One-time copy-forward of pre-rename config files in a config folder: for each
      pair, when the new file does not exist and the old one does, copy it (the old
      file is left as it was, so an older Keystone keeps working). Idempotent: a later
      run never overwrites a Gangplank file. Written to a temp name and renamed, so an
      interrupted copy is simply retried.
    #>
    param([Parameter(Mandatory)][string]$ConfigDir)
    foreach ($pair in $script:GangplankLegacyConfigFiles) {
        $old = Join-Path $ConfigDir $pair[0]
        $new = Join-Path $ConfigDir $pair[1]
        if ((Test-Path -LiteralPath $new) -or -not (Test-Path -LiteralPath $old -PathType Leaf)) { continue }
        $tmp = "$new.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Copy-Item -LiteralPath $old -Destination $tmp -Force -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $new -ErrorAction Stop
            Write-GangplankLog -Level INFO -Message ("Copied {0} to {1} (renamed from Keystone; the original is unchanged)." -f $pair[0], $pair[1])
        } catch {
            Write-GangplankLog -Level WARN -Message ("Could not copy {0} to {1}: {2}" -f $pair[0], $pair[1], $_.Exception.Message)
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Initialize-GangplankConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath) {
        $root = Split-Path $PSScriptRoot -Parent
        $ConfigPath = Join-Path $root "config\gangplank-config.json"
    }
    $script:GangplankConfigPath = $ConfigPath
    $dir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Before the defaults are written: carry an edited keystone-config.json and the
    # per-workstation keystone.local.json / arc-items.local.json forward once.
    Copy-GangplankLegacyConfigFiles -ConfigDir $dir
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $default = [PSCustomObject]@{
            Version      = "1.0"
            LazaretteItems = [PSCustomObject]@{
                GitLab = "gitlab"
                GitHub = "github"
            }
            # Your organization's GitLab host (for example gitlab.example.org). Empty: none.
            GitLabHost   = ""
            LastUsed     = $null
            Repositories = [PSCustomObject]@{}
            LogLevel     = "INFO"
            # false keeps the browser host running after its tab closes (same as GANGPLANK_AUTO_STOP=0).
            AutoStop     = $true
        }
        $default | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        Write-GangplankLog -Level INFO -Message "Created default config at $ConfigPath"
    }
}

function Get-GangplankConfig {
    if (-not $script:GangplankConfigPath -or -not (Test-Path -LiteralPath $script:GangplankConfigPath)) {
        Initialize-GangplankConfig
    }
    try {
        return (Get-Content -LiteralPath $script:GangplankConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-GangplankLog -Level ERROR -Message "Failed to read config: $($_.Exception.Message)"
        return [PSCustomObject]@{
            LazaretteItems = [PSCustomObject]@{
                GitLab = $script:GangplankLazaretteCanonical.GitLab
                GitHub = $script:GangplankLazaretteCanonical.GitHub
            }
            Repositories = [PSCustomObject]@{}
        }
    }
}

function Save-GangplankConfig {
    param($Config)
    if (-not $script:GangplankConfigPath) { Initialize-GangplankConfig }
    try {
        $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:GangplankConfigPath -Encoding UTF8
        Write-GangplankLog -Level DEBUG -Message "Config saved"
    } catch {
        Write-GangplankLog -Level ERROR -Message "Failed to save config: $($_.Exception.Message)"
    }
}

function Get-GangplankEnvLazaretteItem {
    param([string]$Purpose)
    # Prefer tool-specific, then generic ARC_ITEM_* overrides
    # New names first; every pre-rename name (KEYSTONE_*, ARC_*, legacy prefixes) still works,
    # with the current purpose name first and then its legacy aliases.
    $prefixes = @('GANGPLANK_LAZARETTE_ITEM_','KEYSTONE_ARC_ITEM_','LAZARETTE_ITEM_','ARC_ITEM_','HALYARD_LAZARETTE_ITEM_') + @($script:GangplankLegacyAliases.ItemEnvPrefix)
    $names = @()
    foreach ($pn in (@($Purpose) + @(Get-GangplankLegacyPurposeNames -Purpose $Purpose))) {
        foreach ($prefix in $prefixes) { $names += "$prefix$pn" }
    }
    foreach ($n in $names) {
        if (Test-Path "env:$n") {
            $v = (Get-Item "env:$n").Value
            if (-not [string]::IsNullOrWhiteSpace($v)) {
                return $v.Trim()
            }
        }
    }
    return $null
}

# Item NAMES only. Never commit or persist actual token values.
function Get-GangplankLocalLazaretteMappings {
    $out = @{}
    if (-not $script:GangplankConfigPath) { Initialize-GangplankConfig }
    $root = Split-Path $script:GangplankConfigPath -Parent
    $path = Join-Path $root 'lazarette-items.local.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $out }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) {
            $key = Resolve-GangplankPurposeName $property.Name   # a legacy purpose key is read as the current one
            if ($key -cnotin $script:GangplankLazarettePurposes) { continue }
            if ($out.ContainsKey($key) -and $property.Name -cne $key) { continue }   # the current key wins
            if ($property.Value -is [string] -and $property.Value -match '^[a-zA-Z0-9_. -]{1,100}$') {
                $out[$key] = [string]$property.Value
            }
        }
    } catch {
        Write-GangplankLog -Level WARN -Message 'Local Lazarette item name mapping could not be read.'
    }
    return $out
}

function Set-GangplankLazaretteItemName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$ServiceName
    )
    $Provider = Resolve-GangplankPurposeName $Provider
    if ($Provider -cnotin $script:GangplankLazarettePurposes) { throw "Unsupported purpose '$Provider'." }
    if ($ServiceName -cnotmatch '^[a-zA-Z0-9_. -]{1,100}$') {
        throw 'Lazarette item name may contain letters, digits, spaces, dots, dashes and underscores, up to 100 characters.'
    }
    if (-not $script:GangplankConfigPath) { Initialize-GangplankConfig }
    $mappings = Get-GangplankLocalLazaretteMappings
    $mappings[$Provider] = $ServiceName
    $folder = Split-Path $script:GangplankConfigPath -Parent
    $file = Join-Path $folder 'lazarette-items.local.json'
    $tmp = Join-Path $folder ('lazarette-items-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $mappings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $ServiceName
}

function Get-GangplankConfigLazaretteItems {
    # The config's item-name map: LazaretteItems, or ArcItems in a pre-rename file.
    param($Config)
    if ($null -eq $Config) { return $null }
    foreach ($key in @('LazaretteItems','ArcItems')) {
        $p = $Config.PSObject.Properties[$key]
        if ($p -and $p.Value) { return $p.Value }
    }
    return $null
}

function Get-GangplankLazaretteItemName {
    param(
        [string]$Provider
    )
    $Provider = Resolve-GangplankPurposeName $Provider   # accepts legacy purpose names
    if ($Provider -cnotin $script:GangplankLazarettePurposes) { throw "Unsupported purpose '$Provider'." }

    # 1) Env overrides
    $fromEnv = Get-GangplankEnvLazaretteItem -Purpose $Provider
    if ($fromEnv) {
        Write-GangplankLog -Level DEBUG -Message "Lazarette item name from env for $Provider"
        return $fromEnv
    }

    # 2) Per-workstation item-name mappings (ignored by Git)
    $localMapping = Get-GangplankLocalLazaretteMappings
    if ($localMapping.ContainsKey($Provider)) { return [string]$localMapping[$Provider] }

    # 3) Config LazaretteItems (ArcItems in a config file from before the rename)
    $items = Get-GangplankConfigLazaretteItems -Config (Get-GangplankConfig)
    if ($items) {
        foreach ($key in (@($Provider) + @(Get-GangplankLegacyPurposeNames -Purpose $Provider))) {
            $prop = $items.PSObject.Properties[$key]
            if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                return [string]$prop.Value.Trim()
            }
        }
    }

    # 4) Canonical hard-coded fallback
    if ($script:GangplankLazaretteCanonical.ContainsKey($Provider)) {
        return $script:GangplankLazaretteCanonical[$Provider]
    }
    throw "No canonical Lazarette Service name for purpose '$Provider'"
}

function Resolve-GangplankLazaretteItemInCatalog {
    # The item to read for a purpose. When the name is the current default and the vault has
    # no such item but has the item earlier releases used by default, that legacy item is used.
    # The legacy GitLab item holds a token issued for a host earlier releases trusted, so it is
    # used only when a GitLab host was explicitly configured (GANGPLANK_GITLAB_HOST / GitLabHost)
    # and, when -TargetHost is given, only for that configured host.
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string]$Name,[string[]]$Catalog = @(),[string]$TargetHost)
    $Provider = Resolve-GangplankPurposeName $Provider
    if ($Catalog.Count -eq 0 -or $Name -in $Catalog) { return $Name }
    if ($Provider -eq 'GitLab') {
        $configuredHost = ''
        try { $configuredHost = Get-GangplankGitLabHost } catch { $configuredHost = '' }
        if (-not $configuredHost) { return $Name }
        if ($TargetHost -and $TargetHost.Trim().ToLowerInvariant() -ne $configuredHost) { return $Name }
    }
    $legacy = Get-GangplankLegacyItemName -Purpose $Provider
    if ($legacy -and $Name -ieq [string]$script:GangplankLazaretteCanonical[$Provider] -and $legacy -in $Catalog) { return $legacy }
    return $Name
}

function Get-GangplankLazaretteCanonicalMap {
    # Names only - for diagnostics / integrators
    return $script:GangplankLazaretteCanonical.Clone()
}
