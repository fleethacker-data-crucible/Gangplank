#Requires -Version 5.1
# ============================================================
#  Core/Configuration.ps1
#  ARC Service name resolution (names only - never secrets)
# ============================================================
#
# Canonical ARC Service names (hard-coded fallbacks only):
#   gitmil     - GitLab PAT (web.git.mil)
#   github     - GitHub token
#   genapi     - GenAi / api.genai.mil (reserved for future)
#   advana-api - Grok / Advana Databricks (aliases in matchers only)
#
# Resolution order for GitLab / GitHub:
#   1. Env KEYSTONE_ARC_ITEM_<Purpose>  (or ARC_ITEM_<Purpose>)
#   2. config ArcItems.<Purpose>
#   3. Canonical hard-coded name
# ============================================================

$script:KeystoneConfigPath = $null

# Canonical fallbacks - exact ARC Service names
$script:KeystoneArcCanonical = @{
    GitLab = "gitmil"
    GitHub = "github"
    GenAi  = "genapi"
    Advana = "advana-api"
}

function Initialize-KeystoneConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath) {
        $root = Split-Path $PSScriptRoot -Parent
        $ConfigPath = Join-Path $root "config\keystone-config.json"
    }
    $script:KeystoneConfigPath = $ConfigPath
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
        }
        $default | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        Write-KeystoneLog -Level INFO -Message "Created default config at $ConfigPath"
    }
}

function Get-KeystoneConfig {
    if (-not $script:KeystoneConfigPath -or -not (Test-Path -LiteralPath $script:KeystoneConfigPath)) {
        Initialize-KeystoneConfig
    }
    try {
        return (Get-Content -LiteralPath $script:KeystoneConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-KeystoneLog -Level ERROR -Message "Failed to read config: $($_.Exception.Message)"
        return [PSCustomObject]@{
            ArcItems     = [PSCustomObject]@{
                GitLab = $script:KeystoneArcCanonical.GitLab
                GitHub = $script:KeystoneArcCanonical.GitHub
            }
            Repositories = [PSCustomObject]@{}
        }
    }
}

function Save-KeystoneConfig {
    param($Config)
    if (-not $script:KeystoneConfigPath) { Initialize-KeystoneConfig }
    try {
        $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:KeystoneConfigPath -Encoding UTF8
        Write-KeystoneLog -Level DEBUG -Message "Config saved"
    } catch {
        Write-KeystoneLog -Level ERROR -Message "Failed to save config: $($_.Exception.Message)"
    }
}

function Get-KeystoneEnvArcItem {
    param([string]$Purpose)
    # Prefer tool-specific, then generic ARC_ITEM_* overrides
    $names = @(
        "KEYSTONE_ARC_ITEM_$Purpose",
        "ARC_ITEM_$Purpose",
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

function Get-KeystoneArcItemName {
    param(
        [ValidateSet("GitLab","GitHub","GenAi","Advana")]
        [string]$Provider
    )

    # 1) Env overrides
    $fromEnv = Get-KeystoneEnvArcItem -Purpose $Provider
    if ($fromEnv) {
        Write-KeystoneLog -Level DEBUG -Message "ARC item name from env for $Provider"
        return $fromEnv
    }

    # 2) Config ArcItems
    $cfg = Get-KeystoneConfig
    if ($cfg.ArcItems) {
        $prop = $cfg.ArcItems.PSObject.Properties[$Provider]
        if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return [string]$prop.Value.Trim()
        }
    }

    # 3) Canonical hard-coded fallback
    if ($script:KeystoneArcCanonical.ContainsKey($Provider)) {
        return $script:KeystoneArcCanonical[$Provider]
    }
    throw "No canonical ARC Service name for purpose '$Provider'"
}

function Get-KeystoneArcCanonicalMap {
    # Names only - for diagnostics / integrators
    return $script:KeystoneArcCanonical.Clone()
}
