#Requires -Version 5.1
# ============================================================
#  Core/Configuration.ps1
#  Lazarette Service name resolution (names only - never secrets)
# ============================================================
#
# Canonical Lazarette Service names (hard-coded fallbacks only):
#   gitmil     - GitLab PAT (web.git.mil)
#   github     - GitHub token
#   genapi     - GenAi / api.genai.mil (reserved for future)
#   advana-api - Grok / Advana Databricks (aliases in matchers only)
#
# Resolution order for GitLab / GitHub:
#   1. Env GANGPLANK_LAZARETTE_ITEM_<Purpose>, then KEYSTONE_ARC_ITEM_ /
#      LAZARETTE_ITEM_ / ARC_ITEM_ / HALYARD_LAZARETTE_ITEM_ / CASCADE_ARC_ITEM_<Purpose>
#   (Item names like gitmil, github, genapi are data in the user's vault: unchanged.)
#   2. config ArcItems.<Purpose>
#   3. Canonical hard-coded name
# ============================================================

$script:GangplankConfigPath = $null

# Canonical fallbacks - exact Lazarette Service names
$script:GangplankLazaretteCanonical = @{
    GitLab = "gitmil"
    GitHub = "github"
    GenAi  = "genapi"
    Advana = "advana-api"
}

function Initialize-GangplankConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath) {
        $root = Split-Path $PSScriptRoot -Parent
        $ConfigPath = Join-Path $root "config\keystone-config.json"
    }
    $script:GangplankConfigPath = $ConfigPath
    $dir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $default = [PSCustomObject]@{
            Version      = "1.0"
            ArcItems     = [PSCustomObject]@{
                GitLab = "gitmil"
                GitHub = "github"
            }
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
            ArcItems     = [PSCustomObject]@{
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
    # New names first; every pre-rename name (KEYSTONE_*, ARC_*, CASCADE_*) still works.
    $names = @(
        "GANGPLANK_LAZARETTE_ITEM_$Purpose",
        "KEYSTONE_ARC_ITEM_$Purpose",
        "LAZARETTE_ITEM_$Purpose",
        "ARC_ITEM_$Purpose",
        "HALYARD_LAZARETTE_ITEM_$Purpose",
        "CASCADE_ARC_ITEM_$Purpose"
    )
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
    $path = Join-Path $root 'arc-items.local.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $out }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('GitHub','GitLab','GenAi','Advana')) {
            $property = $saved.PSObject.Properties[$key]
            if ($property -and $property.Value -is [string] -and $property.Value -match '^[a-zA-Z0-9_. -]{1,100}$') {
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
        [Parameter(Mandatory)][ValidateSet('GitHub','GitLab','GenAi','Advana')][string]$Provider,
        [Parameter(Mandatory)][string]$ServiceName
    )
    if ($ServiceName -cnotmatch '^[a-zA-Z0-9_. -]{1,100}$') {
        throw 'Lazarette item name may contain letters, digits, spaces, dots, dashes and underscores, up to 100 characters.'
    }
    if (-not $script:GangplankConfigPath) { Initialize-GangplankConfig }
    $mappings = Get-GangplankLocalLazaretteMappings
    $mappings[$Provider] = $ServiceName
    $folder = Split-Path $script:GangplankConfigPath -Parent
    $file = Join-Path $folder 'arc-items.local.json'
    $tmp = Join-Path $folder ('arc-items-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $mappings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $ServiceName
}

function Get-GangplankLazaretteItemName {
    param(
        [ValidateSet("GitLab","GitHub","GenAi","Advana")]
        [string]$Provider
    )

    # 1) Env overrides
    $fromEnv = Get-GangplankEnvLazaretteItem -Purpose $Provider
    if ($fromEnv) {
        Write-GangplankLog -Level DEBUG -Message "Lazarette item name from env for $Provider"
        return $fromEnv
    }

    # 2) Per-workstation item-name mappings (ignored by Git)
    $localMapping = Get-GangplankLocalLazaretteMappings
    if ($localMapping.ContainsKey($Provider)) { return [string]$localMapping[$Provider] }

    # 3) Config ArcItems
    $cfg = Get-GangplankConfig
    if ($cfg.ArcItems) {
        $prop = $cfg.ArcItems.PSObject.Properties[$Provider]
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
