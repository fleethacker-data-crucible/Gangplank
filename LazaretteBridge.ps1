#Requires -Version 5.1
# Gangplank -> Lazarette integration.
#   Load <folder>\lib\Lazarette.ps1 once, then use Unlock-LazaretteVaultInteractive,
#   Get-LazaretteSecret, Get-LazaretteItemNames and Test-LazaretteVaultUnlocked
#   (Lazarette docs/INTEGRATION.md). No other loader or function name is used.
# Status codes (LAZARETTE_NOT_FOUND, LAZARETTE_LOCKED, ...) are a wire format the UI reads.
# Gangplank never implements unlock itself: smart card PIN, passphrase and TOTP prompts are
# Lazarette's own console flow, run once before the web host starts.
# Lazarette is imported exactly once in the same PowerShell process as Gangplank.
# Never unlock the smart card/TOTP vault from an HTTP request handler.
# Never return credentials to browser, diagnostic output, or a log file.

$script:GangplankLazaretteBridgeRoot = $PSScriptRoot
$script:GangplankLazaretteLoaded = $false
$script:GangplankLazaretteRoot = $null
$script:GangplankLazaretteModule = $null
$script:GangplankLazaretteLastError = ''
$script:GangplankLazaretteErrorCode = ''

function Get-GangplankLazaretteLoader {
    # The engine loader in a Lazarette folder: lib\Lazarette.ps1, or $null.
    param([string]$LazaretteRoot)
    if (-not $LazaretteRoot) { return $null }
    $candidate = Join-Path (Join-Path $LazaretteRoot 'lib') 'Lazarette.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

$script:GangplankLazaretteApi = [ordered]@{
    Unlock    = 'Unlock-LazaretteVaultInteractive'
    Secret    = 'Get-LazaretteSecret'
    ItemNames = 'Get-LazaretteItemNames'
    Unlocked  = 'Test-LazaretteVaultUnlocked'
}

function Test-GangplankLazaretteFolder {
    # True when the folder holds lib\Lazarette.ps1.
    [CmdletBinding()]
    param([string]$LazaretteRoot)
    return [bool](Get-GangplankLazaretteLoader -LazaretteRoot $LazaretteRoot)
}

function Find-GangplankLazaretteRoot {
    # Lazarette is opt-in (main #14): only the folder configured in Integrations
    # (config\gangplank.local.json Lazarette.Enabled + Lazarette.Path) or GANGPLANK_LAZARETTE_PATH.
    # No search of sibling folders or the user profile: this is deliberate, so Gangplank never
    # loads code from a place the user did not choose.
    [CmdletBinding()]
    param()
    $configured = Get-GangplankConfiguredLazarettePath
    if (-not $configured) { return $null }
    try {
        $full = [IO.Path]::GetFullPath($configured)
        if (Test-GangplankLazaretteFolder -LazaretteRoot $full) { return $full }
    } catch { }
    return $null
}

function Test-GangplankLazaretteHelpersAvailable {
    # Every integration function is defined.
    [CmdletBinding()]
    param()
    foreach ($name in $script:GangplankLazaretteApi.Values) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { return $false }
    }
    return $true
}

function Get-GangplankLazaretteHelperDiagnostics {
    $d = [ordered]@{}
    foreach ($key in $script:GangplankLazaretteApi.Keys) {
        $d[$key.ToLowerInvariant()] = [bool](Get-Command $script:GangplankLazaretteApi[$key] -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]$d
}

function Import-GangplankLazaretteSession {
    [CmdletBinding()]
    param([switch]$Quiet)
    # Never load the engine again once its functions exist: reloading resets the vault's
    # smart card/TOTP in-memory state.
    if (Test-GangplankLazaretteHelpersAvailable) {
        $script:GangplankLazaretteLoaded = $true
        $script:GangplankLazaretteErrorCode = ''
        $script:GangplankLazaretteLastError = ''
        if (-not $script:GangplankLazaretteModule) {
            $command = Get-Command $script:GangplankLazaretteApi.Unlocked -ErrorAction SilentlyContinue
            if ($command -and $command.Module) { $script:GangplankLazaretteModule = $command.Module }
        }
        return $true
    }
    if (Get-Module -Name GangplankLazarette -ErrorAction SilentlyContinue) {
        $script:GangplankLazaretteErrorCode = 'LAZARETTE_HELPERS_UNAVAILABLE'
        $script:GangplankLazaretteLastError = 'Lazarette module was loaded, but required vault helpers are missing. Verify Lazarette installation and restart Gangplank.'
        return $false
    }
    $lazaretteRoot = Find-GangplankLazaretteRoot
    if (-not $lazaretteRoot) {
        $script:GangplankLazaretteErrorCode = 'LAZARETTE_NOT_FOUND'
        $script:GangplankLazaretteLastError = 'Lazarette was not found. Turn on Lazarette in Integrations with its folder (the one containing lib\Lazarette.ps1), or set GANGPLANK_LAZARETTE_PATH.'
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
    $script:GangplankLazaretteRoot = $lazaretteRoot
    return (Import-GangplankLazaretteEngine -LazaretteRoot $lazaretteRoot -Quiet:$Quiet)
}

function Import-GangplankLazaretteEngine {
    # Load Lazarette's engine once into one dynamic module, so Lazarette's script-scoped
    # session state lives in one place and its functions are visible globally.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LazaretteRoot,[switch]$Quiet)
    $loader = Get-GangplankLazaretteLoader -LazaretteRoot $LazaretteRoot
    try {
        $module = New-Module -Name GangplankLazarette -ScriptBlock {
            param([string]$LoaderPath)
            $ErrorActionPreference = 'Stop'
            . $LoaderPath
            Export-ModuleMember -Function * -ErrorAction SilentlyContinue
        } -ArgumentList $loader
        Import-Module -ModuleInfo $module -Global -ErrorAction Stop -WarningAction SilentlyContinue
        $script:GangplankLazaretteModule = $module
    } catch {
        $script:GangplankLazaretteErrorCode = 'LAZARETTE_LIBRARY_INITIALIZATION_FAILED'
        $script:GangplankLazaretteLastError = 'Lazarette engine (lib\Lazarette.ps1) failed to load (' + $_.Exception.GetType().Name + '). Update the complete Lazarette repository, then restart Gangplank.'
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
    if (-not (Test-GangplankLazaretteHelpersAvailable)) {
        $script:GangplankLazaretteErrorCode = 'LAZARETTE_HELPERS_UNAVAILABLE'
        $script:GangplankLazaretteLastError = 'Lazarette loaded but its integration functions are missing: Unlock-LazaretteVaultInteractive, Get-LazaretteSecret, Get-LazaretteItemNames and Test-LazaretteVaultUnlocked. Update Lazarette.'
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
    $script:GangplankLazaretteLoaded = $true
    $script:GangplankLazaretteErrorCode = ''
    $script:GangplankLazaretteLastError = ''
    if (-not $Quiet) { Write-Host '[+] Lazarette engine loaded into Gangplank host process.' -ForegroundColor Green }
    return $true
}

function Test-GangplankLazaretteVaultUnlocked {
    [CmdletBinding()]
    param()
    if (-not (Test-GangplankLazaretteHelpersAvailable)) { return $false }
    try { return [bool](& $script:GangplankLazaretteApi.Unlocked) } catch { return $false }
}

function Initialize-GangplankLazaretteAuthentication {
    [CmdletBinding()]
    param([switch]$SkipUnlock,[switch]$Quiet)
    if (-not (Get-GangplankConfiguredLazarettePath)) {
        return [pscustomobject]@{ Found = $false; Loaded = $false; Unlocked = $false; Configured = $false; Message = 'Lazarette is not configured.' }
    }
    if (-not (Import-GangplankLazaretteSession -Quiet:$Quiet)) {
        return [pscustomobject]@{
            Found = [bool](Find-GangplankLazaretteRoot); Loaded = $false; Unlocked = $false
            Message = $script:GangplankLazaretteLastError
        }
    }
    if (-not $SkipUnlock -and -not (Test-GangplankLazaretteVaultUnlocked)) {
        if (-not $Quiet) {
            Write-Host ''
            Write-Host '[*] Lazarette authentication: complete the standard smart card + TOTP steps in this PowerShell window.' -ForegroundColor Cyan
            Write-Host '[*] You can cancel to launch Gangplank without Lazarette; env credentials will still work.' -ForegroundColor DarkGray
        }
        try {
            # This is called BEFORE starting the listener, never on an HTTP request.
            # The prompts (smart card PIN or passphrase, then authenticator) are Lazarette's own.
            $unlocked = [bool](& $script:GangplankLazaretteApi.Unlock)
            if (-not $unlocked) { $script:GangplankLazaretteLastError = 'Lazarette authentication was cancelled or declined.' }
        } catch {
            $script:GangplankLazaretteLastError = 'Lazarette unlock failed (' + $_.Exception.GetType().Name + ').'
        }
    }
    $ready = Test-GangplankLazaretteVaultUnlocked
    if ($ready) {
        $script:GangplankLazaretteLastError = ''
        if (-not $Quiet) { Write-Host '[+] Lazarette vault unlocked in the Gangplank host process.' -ForegroundColor Green }
    } elseif (-not $Quiet) {
        Write-Warning 'Lazarette is locked. Restart Gangplank and complete smart card/TOTP, or use an approved environment credential.'
    }
    return [pscustomobject]@{
        Found = $true; Loaded = $true; Unlocked = [bool]$ready
        Message = $(if ($ready) { 'Lazarette is unlocked.' } else { $script:GangplankLazaretteLastError })
    }
}

function Get-GangplankLazaretteServiceNames {
    [CmdletBinding()]
    param()
    if (-not (Test-GangplankLazaretteVaultUnlocked)) { return @() }
    try {
        return @(@(& $script:GangplankLazaretteApi.ItemNames) | ForEach-Object { [string]$_.Service } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    } catch { return @() }
}

function Get-GangplankLazaretteConnectionStatus {
    [CmdletBinding()]
    param()
    $configured = Get-GangplankConfiguredLazarettePath
    $root = Find-GangplankLazaretteRoot
    $loaded = Test-GangplankLazaretteHelpersAvailable
    $unlocked = Test-GangplankLazaretteVaultUnlocked
    $names = @()
    if ($unlocked) { $names = @(Get-GangplankLazaretteServiceNames) }
    $bindings = @()
    foreach ($purpose in @('GitHub','GitLab','AI')) {
        $item = Get-GangplankLazaretteItemName -Provider $purpose
        $envNames = switch ($purpose) {
            'GitHub' { @('GITHUB_TOKEN') }
            'GitLab' { @('GITLAB_TOKEN') }
            'AI' { @('GANGPLANK_AI_TOKEN') }
        }
        $envPresent = $false
        foreach ($envName in $envNames) { if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) { $envPresent = $true } }
        $present = [bool]($unlocked -and ($names -contains $item))
        $bindings += [pscustomobject]@{
            provider = $purpose; item = $item
            configured = [bool]($envPresent -or $present)
            source = $(if ($envPresent) { 'environment' } elseif ($present) { 'lazarette' } else { 'none' })
            lazaretteItemFound = $present
        }
    }
    return [pscustomobject]@{
        lazaretteFound = [bool]$root
        lazaretteLoaded = [bool]$loaded
        lazaretteUnlocked = [bool]$unlocked
        lazarettePath = $(if ($root) { $root } else { '' })
        lazaretteVersion = $(if ($loaded -or $root) { '5' } else { '' })
        code = $(if (-not $configured) { 'LAZARETTE_NOT_CONFIGURED' } elseif ($loaded) { '' } elseif ($script:GangplankLazaretteErrorCode) { $script:GangplankLazaretteErrorCode } else { 'LAZARETTE_NOT_LOADED' })
        helpers = Get-GangplankLazaretteHelperDiagnostics
        configured = [bool]$configured
        message = $(if (-not $configured) { 'Lazarette is not configured. It is optional: enable it in Integrations with the Lazarette folder path.' }
                    elseif ($loaded -and $unlocked) { 'Lazarette is unlocked.' }
                    elseif ($loaded) { 'Lazarette loaded but locked. Restart Gangplank and complete smart card + TOTP in its console.' }
                    elseif ($script:GangplankLazaretteLastError) { $script:GangplankLazaretteLastError }
                    elseif (-not $root) { 'Lazarette not found. Turn on Lazarette in Integrations with its folder (the one containing lib\Lazarette.ps1), or set GANGPLANK_LAZARETTE_PATH.' }
                    else { 'Lazarette was located but could not be loaded. Check the Gangplank console and Lazarette installation.' })
        integrations = @($bindings)
        # Only service names, never usernames, passwords or API keys.
        itemNames = @($names)
    }
}

function Get-GangplankLazaretteSecretByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    # Never prompt for smart card/TOTP as a side effect of a browser request.
    if (-not (Test-GangplankLazaretteVaultUnlocked)) { return $null }
    if ($ServiceName.Length -gt 100) { return $null }
    # Get-LazaretteSecret throws when the item is missing or ambiguous; the reason is recorded
    # without the secret and the caller reports LAZARETTE_ITEM_UNREADABLE.
    try {
        $value = & $script:GangplankLazaretteApi.Secret -Service $ServiceName
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    } catch {
        $reason = [string]$_.Exception.Message
        $script:GangplankLazaretteLastError = if ($reason -match 'items named') { "Lazarette has more than one item named '$ServiceName'. Rename one in Lazarette." } else { "Lazarette item '$ServiceName' could not be read." }
    }
    return $null
}

function Test-GangplankLazaretteAvailable {
    return [bool](Find-GangplankLazaretteRoot)
}

function Get-GangplankLazaretteCredential {
    # Token for a provider from the configured Lazarette vault, or a coded error that
    # says exactly why not. Never prompts: unlock happens at startup only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    $Provider = Resolve-GangplankPurposeName $Provider
    if ($Provider -notin @('GitHub','GitLab','AI')) { throw "Unsupported credential provider '$Provider'." }
    $name = Get-GangplankLazaretteItemName -Provider $Provider
    $status = Get-GangplankLazaretteConnectionStatus
    if (-not $status.lazaretteFound) { throw "LAZARETTE_NOT_FOUND|$($status.message)" }
    if (-not $status.lazaretteLoaded) {
        $reason = if ($status.message) { [string]$status.message } else { 'Lazarette module could not be loaded.' }
        throw "LAZARETTE_UNAVAILABLE|$reason"
    }
    if (-not $status.lazaretteUnlocked) {
        throw 'LAZARETTE_LOCKED|Lazarette is configured but locked. Restart Gangplank and complete the Lazarette unlock in its PowerShell window.'
    }
    $catalogNames = @($status.itemNames)
    if ($catalogNames.Count -gt 0 -and $name -notin $catalogNames) {
        throw "LAZARETTE_ITEM_MISSING|Lazarette vault has no item named '$name' for $Provider. Choose an existing item in Integrations."
    }
    $token = Get-GangplankLazaretteSecretByName -ServiceName $name
    if (-not $token) {
        throw "LAZARETTE_ITEM_UNREADABLE|Lazarette item '$name' for $Provider was missing, empty, ambiguous, or could not be read. Check it in Lazarette."
    }
    Write-GangplankLog -Level INFO -Message "Credential source for $($Provider): Lazarette item '$name' (value not logged)."
    return $token
}
