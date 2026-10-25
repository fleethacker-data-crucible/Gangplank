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
#   2. config\lazarette-items.local.json (per-workstation picker mapping)
#   3. config LazaretteItems.<Purpose> (ArcItems in a pre-rename config file)
#   4. Canonical hard-coded name
# ============================================================

$script:GangplankConfigPath = $null

# Canonical fallbacks - exact Lazarette Service names
$script:GangplankLazaretteCanonical = @{
    GitLab = "gitmil"
    GitHub = "github"
    GenAi  = "genapi"
    Advana = "advana-api"
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
    $path = Join-Path $root 'lazarette-items.local.json'
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

    # 3) Config LazaretteItems (ArcItems in a config file from before the rename)
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
