#Requires -Version 5.1
# ============================================================
#  Core/Configuration.ps1
#  Lazarette Service name resolution (names only - never secrets)
# ============================================================
#
# Canonical Lazarette Service names (hard-coded fallbacks only):
#   gitlab            - GitLab PAT (your organization's GitLab host)
#   github            - GitHub token
#   data-platform-api - enterprise data platform token (purpose DataPlatform; reserved)
#
# Resolution order for GitLab / GitHub:
#   1. Env GANGPLANK_LAZARETTE_ITEM_<Purpose>
#   (Item names are data in the user's vault: Gangplank never renames them.)
#   2. config\lazarette-items.local.json (per-workstation picker mapping)
#   3. config LazaretteItems.<Purpose>
#   4. Canonical hard-coded name
# ============================================================

$script:GangplankConfigPath = $null

# Canonical fallbacks - exact Lazarette Service names
$script:GangplankLazaretteCanonical = @{
    GitLab       = "gitlab"
    GitHub       = "github"
    DataPlatform = "data-platform-api"
}
$script:GangplankLazarettePurposes = @('GitHub','GitLab','DataPlatform')

function Resolve-GangplankPurposeName {
    # The purpose name in its canonical spelling; anything else is returned trimmed.
    # Case-insensitive by default; -Strict matches the exact spelling only (credential provider checks).
    param([AllowNull()][AllowEmptyString()][string]$Name,[switch]$Strict)
    $n = ([string]$Name).Trim()
    if ($Strict) { return $n }
    foreach ($k in $script:GangplankLazarettePurposes) { if ($k -ieq $n) { return $k } }
    return $n
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
    # GANGPLANK_LAZARETTE_ITEM_<Purpose> is the only override (Lazarette docs/FLEET-ITEMS.md).
    foreach ($n in @("GANGPLANK_LAZARETTE_ITEM_$Purpose")) {
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
            $key = Resolve-GangplankPurposeName $property.Name
            if ($key -cnotin $script:GangplankLazarettePurposes) { continue }
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
    # The config's item-name map (LazaretteItems).
    param($Config)
    if ($null -eq $Config) { return $null }
    $p = $Config.PSObject.Properties['LazaretteItems']
    if ($p -and $p.Value) { return $p.Value }
    return $null
}

function Get-GangplankLazaretteItemName {
    param(
        [string]$Provider
    )
    $Provider = Resolve-GangplankPurposeName $Provider
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

    # 3) Config LazaretteItems
    $items = Get-GangplankConfigLazaretteItems -Config (Get-GangplankConfig)
    if ($items) {
        $prop = $items.PSObject.Properties[$Provider]
        if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return [string]$prop.Value.Trim()
        }
    }

    # 4) Canonical hard-coded fallback
    if ($script:GangplankLazaretteCanonical.ContainsKey($Provider)) {
        return $script:GangplankLazaretteCanonical[$Provider]
    }
    throw "No canonical Lazarette Service name for purpose '$Provider'"
}

function Get-GangplankLazaretteCanonicalMap {
    # Names only - for diagnostics / integrators
    return $script:GangplankLazaretteCanonical.Clone()
}
