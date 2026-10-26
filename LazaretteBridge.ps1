#Requires -Version 5.1
# Gangplank -> Lazarette (formerly ARC) integration.
#   Lazarette / ARC 5 (current): . <folder>\lib\Lazarette.ps1 (or the older lib\Arc.ps1), then
#                     Unlock-LazaretteVaultInteractive, Get-LazaretteSecret,
#                     Get-LazaretteItemNames, Test-LazaretteVaultUnlocked; each falls back
#                     to its former ARC name (Unlock-ArcVaultInteractive, Get-ArcSecret, ...)
#                     when the Lazarette name is not defined (Lazarette docs/INTEGRATION.md).
#   ARC 3/4 (legacy): pm.ps1 with Ensure-VaultUnlocked / Get-PmStarkApiKey etc.
# Lazarette (ARC 5) ships a pm.ps1 stub that only throws; it is never treated as ARC 3/4.
# The ARC_* status codes (ARC_NOT_FOUND, ARC_LOCKED, ...) are a wire format the UI
# reads; they keep their names.
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
$script:GangplankLazaretteMissingModules = @()
$script:GangplankLazaretteFlavor = ''

function Get-GangplankLazaretteLoader {
    # The engine loader in a Lazarette / ARC 5 folder: lib\Lazarette.ps1 first, then lib\Arc.ps1.
    param([string]$LazaretteRoot)
    if (-not $LazaretteRoot) { return $null }
    foreach ($name in @('Lazarette.ps1','Arc.ps1')) {
        $candidate = Join-Path (Join-Path $LazaretteRoot 'lib') $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-GangplankLazaretteCommandName {
    # The first defined command of a Lazarette name and its former ARC name.
    param([Parameter(Mandatory)][string[]]$Names)
    foreach ($n in $Names) { if (Get-Command $n -ErrorAction SilentlyContinue) { return $n } }
    return $null
}

$script:GangplankLazaretteApi = [ordered]@{
    Unlock    = @('Unlock-LazaretteVaultInteractive','Unlock-ArcVaultInteractive')
    Secret    = @('Get-LazaretteSecret','Get-ArcSecret')
    ItemNames = @('Get-LazaretteItemNames','Get-ArcItemNames')
    Unlocked  = @('Test-LazaretteVaultUnlocked','Test-ArcVaultUnlocked')
}

function Get-GangplankLazaretteFlavor {
    # 'v5' when lib\Lazarette.ps1 or lib\Arc.ps1 exists (Lazarette / ARC 5), 'legacy' for a
    # real ARC 3/4 pm.ps1, else ''.
    [CmdletBinding()]
    param([string]$LazaretteRoot)
    if (-not $LazaretteRoot) { return '' }
    if (Get-GangplankLazaretteLoader -LazaretteRoot $LazaretteRoot) { return 'v5' }
    $pm = Join-Path $LazaretteRoot 'pm.ps1'
    if (Test-Path -LiteralPath $pm -PathType Leaf) {
        try {
            if ([IO.File]::ReadAllText($pm) -match '(ARC 5|Lazarette) no longer provides pm\.ps1') { return '' }
        } catch { return '' }
        return 'legacy'
    }
    return ''
}

function Test-GangplankLazarette5HelpersAvailable {
    # Every integration function, under its Lazarette name or its former ARC name.
    foreach ($names in $script:GangplankLazaretteApi.Values) {
        if (-not (Get-GangplankLazaretteCommandName -Names $names)) { return $false }
    }
    return $true
}

function Find-GangplankLazaretteRoot {
    # Lazarette is opt-in (main #14): only the folder configured in Integrations
    # (config\gangplank.local.json Lazarette.Enabled + Lazarette.Path) or GANGPLANK_LAZARETTE_PATH
    # (formerly KEYSTONE_ARC_PATH). No search of LAZARETTE_PATH / ARC_PATH, sibling
    # folders or the user profile. The folder may hold lib\Lazarette.ps1 or lib\Arc.ps1.
    [CmdletBinding()]
    param()
    $configured = Get-GangplankConfiguredLazarettePath
    if (-not $configured) { return $null }
    try {
        $full = [IO.Path]::GetFullPath($configured)
        if (Get-GangplankLazaretteFlavor -LazaretteRoot $full) { return $full }
    } catch { }
    return $null
}

function Get-GangplankLazaretteRequiredFiles {
    [CmdletBinding()]
    param([string]$LazaretteRoot)
    # Read Lazarette's declared library names. Different Lazarette releases can ship
    # different sets: never insist on Gangplank's preferred STARK version.
    if (-not $LazaretteRoot) {
        # Fixed current-Lazarette reference, useful for regression tests only.
        return @(
            'lib/00-logging.ps1','lib/00-core.ps1','lib/01-storage.ps1',
            'lib/02-cac.ps1','lib/03-totp-core.ps1','lib/03-totp-recovery.ps1',
            'lib/03-totp-setup.ps1','lib/04-wincred.ps1','lib/05-update.ps1',
            'lib/06-ui.ps1','lib/07-cli.ps1','lib/08-gui.ps1',
            'lib/09-integrity.ps1','lib/10-stark.ps1'
        )
    }
    $pmPath = Join-Path $LazaretteRoot 'pm.ps1'
    if (-not (Test-Path -LiteralPath $pmPath -PathType Leaf)) { return @() }
    try {
        $source = [IO.File]::ReadAllText($pmPath)
        $list = [regex]::Match($source, '(?s)\$libOrder\s*=\s*@\((.*?)\)')
        if (-not $list.Success) { return @() }
        $files = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($list.Groups[1].Value, "'([A-Za-z0-9._-]+\.ps1)'")) {
            [void]$files.Add(('lib/' + $m.Groups[1].Value))
        }
        return @($files.ToArray())
    } catch { return @() }
}

function Get-GangplankLazaretteMissingFiles {
    [CmdletBinding()]
    param([string]$LazaretteRoot)
    if (-not $LazaretteRoot) { return @() }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-GangplankLazaretteRequiredFiles -LazaretteRoot $LazaretteRoot)) {
        if (-not (Test-Path -LiteralPath (Join-Path $LazaretteRoot $name) -PathType Leaf)) {
            [void]$missing.Add($name)
        }
    }
    return @($missing.ToArray())
}

function Test-GangplankLazaretteHelpersAvailable {
    [CmdletBinding()]
    param()
    if (Test-GangplankLazarette5HelpersAvailable) { return $true }
    $unlock = [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
    $stark = [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue)
    $finder = [bool](Get-Command Find-VaultRows -ErrorAction SilentlyContinue)
    $vault = [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue)
    $decrypt = [bool](Get-Command Unprotect-SecretText -ErrorAction SilentlyContinue)
    # Older Lazarette builds may lack the optional STARK helper, yet retain all
    # vault APIs needed to decrypt an item. Do not require STARK by name.
    return ($unlock -and ($stark -or ($decrypt -and ($finder -or $vault))))
}

function Get-GangplankLazaretteHelperDiagnostics {
    return [pscustomobject]@{
        lazarette = [bool](Test-GangplankLazarette5HelpersAvailable)
        unlock = [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
        stark = [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue)
        find = [bool](Get-Command Find-VaultRows -ErrorAction SilentlyContinue)
        vault = [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue)
        decrypt = [bool](Get-Command Unprotect-SecretText -ErrorAction SilentlyContinue)
    }
}

function Import-GangplankLazaretteSession {
    [CmdletBinding()]
    param([switch]$Quiet)
    # Never source pm.ps1 again once the Lazarette functions have been loaded;
    # reloading resets the vault's smart card/TOTP in-memory state.
    if (Test-GangplankLazaretteHelpersAvailable) {
        $script:GangplankLazaretteLoaded = $true
        $script:GangplankLazaretteErrorCode = ''
        $script:GangplankLazaretteLastError = ''
        if (-not $script:GangplankLazaretteFlavor) { $script:GangplankLazaretteFlavor = $(if (Test-GangplankLazarette5HelpersAvailable) { 'v5' } else { 'legacy' }) }
        if (-not $script:GangplankLazaretteModule) {
            $name = if ($script:GangplankLazaretteFlavor -eq 'v5') { Get-GangplankLazaretteCommandName -Names $script:GangplankLazaretteApi.Unlocked } else { 'Ensure-VaultUnlocked' }
            $command = Get-Command $name -ErrorAction SilentlyContinue
            if ($command -and $command.Module) { $script:GangplankLazaretteModule = $command.Module }
        }
        return $true
    }
    if (Get-Module -Name GangplankLazarette -ErrorAction SilentlyContinue) {
        $script:GangplankLazaretteErrorCode = 'ARC_HELPERS_UNAVAILABLE'
        $script:GangplankLazaretteLastError = 'Lazarette module was loaded, but required vault helpers are missing. Verify Lazarette installation and restart Gangplank.'
        return $false
    }
    $lazaretteRoot = Find-GangplankLazaretteRoot
    if (-not $lazaretteRoot) {
        $script:GangplankLazaretteErrorCode = 'ARC_NOT_FOUND'
        $script:GangplankLazaretteLastError = 'Lazarette was not found. Turn on Lazarette in Integrations with its folder (the one containing lib\Lazarette.ps1 or lib\Arc.ps1), or set GANGPLANK_LAZARETTE_PATH.'
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
    $script:GangplankLazaretteRoot = $lazaretteRoot
    $script:GangplankLazaretteFlavor = Get-GangplankLazaretteFlavor -LazaretteRoot $lazaretteRoot
    if ($script:GangplankLazaretteFlavor -eq 'v5') { return (Import-GangplankLazarette5 -LazaretteRoot $lazaretteRoot -Quiet:$Quiet) }
    $script:GangplankLazaretteMissingModules = @(Get-GangplankLazaretteMissingFiles -LazaretteRoot $lazaretteRoot)
    if ($script:GangplankLazaretteMissingModules.Count -gt 0) {
        $script:GangplankLazaretteErrorCode = 'ARC_MISSING_MODULES'
        $script:GangplankLazaretteLastError = 'Lazarette installation is incomplete. Missing libraries: ' + ($script:GangplankLazaretteMissingModules -join ', ') + '. Update the full Lazarette repository rather than copying pm.ps1 alone.'
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
    try {
        $pm = Join-Path $lazaretteRoot 'pm.ps1'
        # Like Halyard, import all of Lazarette's commands from a single dynamic module.
        # A child PowerShell process cannot inherit Lazarette's unlocked session.
        $module = New-Module -Name GangplankLazarette -ScriptBlock {
            param([string]$PmPath)
            $ErrorActionPreference = 'Continue'
            . $PmPath
            Export-ModuleMember -Function * -Alias * -ErrorAction SilentlyContinue
        } -ArgumentList $pm
        Import-Module -ModuleInfo $module -Global -ErrorAction Stop -WarningAction SilentlyContinue
        $script:GangplankLazaretteModule = $module
        if (-not (Test-GangplankLazaretteHelpersAvailable)) {
            $script:GangplankLazaretteErrorCode = 'ARC_HELPERS_UNAVAILABLE'
            $script:GangplankLazaretteLastError = 'Lazarette imported but required helpers are missing. Check Lazarette lib modules and use the diagnostics in Gangplank Integrations.'
            if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
            return $false
        }
        $script:GangplankLazaretteLoaded = $true
        $script:GangplankLazaretteErrorCode = ''
        $script:GangplankLazaretteLastError = ''
        if (-not $Quiet) { Write-Host '[+] Lazarette module loaded into Gangplank host process.' -ForegroundColor Green }
        return $true
    } catch {
        # ARC's loader throws "ARC load incomplete (N error(s))" if a
        # library cannot initialize. Classify it without forwarding raw error
        # messages, tokens, or vault data to the browser.
        $kind = $_.Exception.GetType().Name
        if ($_.Exception.Message -match 'ARC load incomplete') {
            $script:GangplankLazaretteErrorCode = 'ARC_LIBRARY_INITIALIZATION_FAILED'
            $script:GangplankLazaretteLastError = 'Lazarette pm.ps1 reported one or more library initialization failures. Open Lazarette itself and inspect its local error log, then restart Gangplank.'
        } else {
            $script:GangplankLazaretteErrorCode = 'ARC_IMPORT_EXCEPTION'
            $script:GangplankLazaretteLastError = 'Lazarette import failed (' + $kind + '). Open Lazarette directly to inspect its local diagnostics. Gangplank did not modify the vault.'
        }
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
}

function Import-GangplankLazarette5 {
    # Load Lazarette's engine once into one dynamic module, so Lazarette's script-scoped
    # session state lives in one place and its functions are visible globally.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LazaretteRoot,[switch]$Quiet)
    $loader = Get-GangplankLazaretteLoader -LazaretteRoot $LazaretteRoot
    $script:GangplankLazaretteMissingModules = @()
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
        $script:GangplankLazaretteErrorCode = 'ARC_LIBRARY_INITIALIZATION_FAILED'
        $script:GangplankLazaretteLastError = 'Lazarette engine (lib\Lazarette.ps1 / lib\Arc.ps1) failed to load (' + $_.Exception.GetType().Name + '). Update the complete Lazarette repository, then restart Gangplank.'
        if (-not $Quiet) { Write-Warning $script:GangplankLazaretteLastError }
        return $false
    }
    if (-not (Test-GangplankLazarette5HelpersAvailable)) {
        $script:GangplankLazaretteErrorCode = 'ARC_HELPERS_UNAVAILABLE'
        $script:GangplankLazaretteLastError = 'Lazarette loaded but its integration functions are missing: Unlock-LazaretteVaultInteractive, Get-LazaretteSecret, Get-LazaretteItemNames and Test-LazaretteVaultUnlocked (or their ARC names Unlock-ArcVaultInteractive, Get-ArcSecret, Get-ArcItemNames, Test-ArcVaultUnlocked). Update Lazarette.'
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
    if (Test-GangplankLazarette5HelpersAvailable) {
        try { return [bool](& (Get-GangplankLazaretteCommandName -Names $script:GangplankLazaretteApi.Unlocked)) } catch { return $false }
    }
    if (-not (Test-GangplankLazaretteHelpersAvailable)) { return $false }
    $module = $script:GangplankLazaretteModule
    if (-not $module) {
        $cmd = Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue
        if ($cmd) { $module = $cmd.Module }
    }
    if (-not $module) { return $false }
    try {
        return [bool](& $module {
            if ($script:PmState -is [hashtable] -and $script:PmState.ContainsKey('VaultUnlocked')) {
                return [bool]$script:PmState.VaultUnlocked
            }
            return [bool]$script:VaultUnlocked
        })
    } catch { return $false }
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
            $unlocked = if (Test-GangplankLazarette5HelpersAvailable) { [bool](& (Get-GangplankLazaretteCommandName -Names $script:GangplankLazaretteApi.Unlock)) } else { [bool](Ensure-VaultUnlocked) }
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

function Convert-GangplankLazaretteVaultRows {
    # Lazarette sometimes returns an ArrayList with an extra unary-comma wrapper.
    # Flatten collections before selecting by Service (not $list.Service).
    [CmdletBinding()]
    param($InputObject)
    $queue = New-Object System.Collections.Queue
    $results = New-Object System.Collections.Generic.List[object]
    if ($null -ne $InputObject) { $queue.Enqueue($InputObject) }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($null -eq $item) { continue }
        if ($item -is [System.Collections.IList] -and -not ($item -is [string])) {
            foreach ($child in $item) { if ($null -ne $child) { $queue.Enqueue($child) } }
        } elseif ($item.PSObject.Properties.Name -contains 'Service') {
            [void]$results.Add($item)
        }
    }
    return @($results.ToArray())
}

function Get-GangplankLazaretteServiceNames {
    [CmdletBinding()]
    param()
    if (-not (Test-GangplankLazaretteVaultUnlocked)) { return @() }
    if (Test-GangplankLazarette5HelpersAvailable) {
        try {
            return @(@(& (Get-GangplankLazaretteCommandName -Names $script:GangplankLazaretteApi.ItemNames)) | ForEach-Object { [string]$_.Service } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        } catch { return @() }
    }
    $catalog = $null
    if (Get-Command Get-PmVaultNameCatalog -ErrorAction SilentlyContinue) {
        try { $catalog = Get-PmVaultNameCatalog } catch { }
    }
    if ($null -eq $catalog -and (Get-Command Get-LiveVault -ErrorAction SilentlyContinue)) {
        try { $catalog = Get-LiveVault } catch { }
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($row in (Convert-GangplankLazaretteVaultRows -InputObject $catalog)) {
        $name = [string]$row.Service
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$names.Add($name) }
    }
    return @($names.ToArray() | Sort-Object -Unique)
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
        if ($unlocked) { $item = Resolve-GangplankLazaretteItemInCatalog -Provider $purpose -Name $item -Catalog $names }
        $envNames = switch ($purpose) {
            'GitHub' { @('GITHUB_TOKEN') }
            'GitLab' { @('GITLAB_TOKEN') }
            'AI' { @('GANGPLANK_AI_TOKEN','KEYSTONE_AI_TOKEN') + @($script:GangplankLegacyAliases.TokenEnv['AI']) }
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
        lazaretteVersion = $(if ($loaded -and (Test-GangplankLazarette5HelpersAvailable)) { '5' } elseif ($loaded) { 'legacy' } elseif ($root) { $(if ((Get-GangplankLazaretteFlavor -LazaretteRoot $root) -eq 'v5') { '5' } else { 'legacy' }) } else { '' })
        code = $(if (-not $configured) { 'ARC_NOT_CONFIGURED' } elseif ($loaded) { '' } elseif ($script:GangplankLazaretteErrorCode) { $script:GangplankLazaretteErrorCode } else { 'ARC_NOT_LOADED' })
        missingModules = @($script:GangplankLazaretteMissingModules)
        helpers = Get-GangplankLazaretteHelperDiagnostics
        configured = [bool]$configured
        message = $(if (-not $configured) { 'Lazarette is not configured. It is optional: enable it in Integrations with the Lazarette folder path.' }
                    elseif ($loaded -and $unlocked) { 'Lazarette is unlocked.' }
                    elseif ($loaded) { 'Lazarette loaded but locked. Restart Gangplank and complete smart card + TOTP in its console.' }
                    elseif ($script:GangplankLazaretteLastError) { $script:GangplankLazaretteLastError }
                    elseif (-not $root) { 'Lazarette not found. Turn on Lazarette in Integrations with its folder (the one containing lib\Lazarette.ps1 or lib\Arc.ps1), or set GANGPLANK_LAZARETTE_PATH.' }
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
    if (Test-GangplankLazarette5HelpersAvailable) {
        # Get-LazaretteSecret (formerly Get-ArcSecret) throws when the item is missing or
        # ambiguous; the reason is recorded without the secret and the caller reports
        # ARC_ITEM_UNREADABLE.
        try {
            $value = & (Get-GangplankLazaretteCommandName -Names $script:GangplankLazaretteApi.Secret) -Service $ServiceName
            if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        } catch {
            $reason = [string]$_.Exception.Message
            $script:GangplankLazaretteLastError = if ($reason -match 'items named') { "Lazarette has more than one item named '$ServiceName'. Rename one in Lazarette." } else { "Lazarette item '$ServiceName' could not be read." }
        }
        return $null
    }

    if (Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) {
        try {
            $key = Get-PmStarkApiKey -VaultName $ServiceName
            if ($key -is [string] -and -not [string]::IsNullOrWhiteSpace($key)) {
                return $key.Trim()
            }
        } catch {
            # Fall back to the core Lazarette vault APIs if this optional helper
            # is unavailable for a particular item or Lazarette release.
        }
    }
    $row = $null
    if (Get-Command Find-VaultRows -ErrorAction SilentlyContinue) {
        try {
            $hits = Find-VaultRows -Name $ServiceName
            foreach ($hit in (Convert-GangplankLazaretteVaultRows -InputObject $hits)) {
                if ([string]$hit.Service -eq $ServiceName) { $row = $hit; break }
            }
        } catch { }
    }
    if (-not $row -and (Get-Command Get-LiveVault -ErrorAction SilentlyContinue)) {
        try {
            $hits = Get-LiveVault
            foreach ($hit in (Convert-GangplankLazaretteVaultRows -InputObject $hits)) {
                if ([string]$hit.Service -eq $ServiceName) { $row = $hit; break }
            }
        } catch { }
    }
    if (-not $row) { return $null }
    $protected = [string]$row.Secret
    if ([string]::IsNullOrWhiteSpace($protected)) { return $null }
    if (Get-Command Unprotect-SecretText -ErrorAction SilentlyContinue) {
        try {
            $plain = Unprotect-SecretText -Protected $protected
            if ($plain -is [string] -and -not [string]::IsNullOrWhiteSpace($plain)) {
                return $plain.Trim()
            }
        } catch { }
    }
    # Core Lazarette compatibility: legacy DPAPI SecureString payloads.
    try {
        $secure = ConvertTo-SecureString $protected -ErrorAction Stop
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain.Trim() }
        } finally {
            if ($ptr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }
    } catch { }
    # Never silently return encrypted blob content as a token.
    return $null
}

function Test-GangplankLazaretteAvailable {
    return [bool](Find-GangplankLazaretteRoot)
}

function Get-GangplankLazaretteCredential {
    # Token for a provider from the configured Lazarette vault, or a coded error that
    # says exactly why not. Never prompts: unlock happens at startup only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider,[string]$TargetHost)
    $Provider = Resolve-GangplankPurposeName $Provider   # accepts legacy purpose names
    if ($Provider -notin @('GitHub','GitLab','AI')) { throw "Unsupported credential provider '$Provider'." }
    $name = Get-GangplankLazaretteItemName -Provider $Provider
    $status = Get-GangplankLazaretteConnectionStatus
    if (-not $status.lazaretteFound) { throw "ARC_NOT_FOUND|$($status.message)" }
    if (-not $status.lazaretteLoaded) {
        $reason = if ($status.message) { [string]$status.message } else { 'Lazarette module could not be loaded.' }
        throw "ARC_UNAVAILABLE|$reason"
    }
    if (-not $status.lazaretteUnlocked) {
        throw 'ARC_LOCKED|Lazarette is configured but locked. Restart Gangplank and complete the Lazarette unlock in its PowerShell window.'
    }
    $catalogNames = @($status.itemNames)
    $name = Resolve-GangplankLazaretteItemInCatalog -Provider $Provider -Name $name -Catalog $catalogNames -TargetHost $TargetHost   # legacy default item name
    if ($catalogNames.Count -gt 0 -and $name -notin $catalogNames) {
        throw "ARC_ITEM_MISSING|Lazarette vault has no item named '$name' for $Provider. Choose an existing item in Integrations."
    }
    $token = Get-GangplankLazaretteSecretByName -ServiceName $name
    if (-not $token) {
        throw "ARC_ITEM_UNREADABLE|Lazarette item '$name' for $Provider was missing, empty, ambiguous, or could not be read. Check it in Lazarette."
    }
    Write-GangplankLog -Level INFO -Message "Credential source for $($Provider): Lazarette item '$name' (value not logged)."
    return $token
}
