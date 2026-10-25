#Requires -Version 5.1
# Keystone -> ARC integration.
#   ARC 5 (current):  . <arc>\lib\Arc.ps1, Unlock-ArcVaultInteractive, Get-ArcSecret,
#                     Get-ArcItemNames, Test-ArcVaultUnlocked (ARC docs/INTEGRATION.md).
#   ARC 3/4 (legacy): pm.ps1 with Ensure-VaultUnlocked / Get-PmStarkApiKey etc.
# ARC 5 ships a pm.ps1 stub that only throws; it is never treated as ARC 3/4.
# Keystone never implements unlock itself: CAC PIN, passphrase and TOTP prompts are
# ARC's own console flow, run once before the web host starts.
# ARC is imported exactly once in the same PowerShell process as Keystone.
# Never unlock the CAC/TOTP vault from an HTTP request handler.
# Never return credentials to browser, diagnostic output, or a log file.

$script:KeystoneArcBridgeRoot = $PSScriptRoot
$script:KeystoneArcLoaded = $false
$script:KeystoneArcRoot = $null
$script:KeystoneArcModule = $null
$script:KeystoneArcLastError = ''
$script:KeystoneArcErrorCode = ''
$script:KeystoneArcMissingModules = @()
$script:KeystoneArcFlavor = ''

function Get-KeystoneArcFlavor {
    # 'v5' when lib\Arc.ps1 exists, 'legacy' for a real ARC 3/4 pm.ps1, else ''.
    [CmdletBinding()]
    param([string]$ArcRoot)
    if (-not $ArcRoot) { return '' }
    if (Test-Path -LiteralPath (Join-Path (Join-Path $ArcRoot 'lib') 'Arc.ps1') -PathType Leaf) { return 'v5' }
    $pm = Join-Path $ArcRoot 'pm.ps1'
    if (Test-Path -LiteralPath $pm -PathType Leaf) {
        try {
            if ([IO.File]::ReadAllText($pm) -match 'ARC 5 no longer provides pm\.ps1') { return '' }
        } catch { return '' }
        return 'legacy'
    }
    return ''
}

function Test-KeystoneArc5HelpersAvailable {
    return ([bool](Get-Command Unlock-ArcVaultInteractive -ErrorAction SilentlyContinue) -and
            [bool](Get-Command Get-ArcSecret -ErrorAction SilentlyContinue) -and
            [bool](Get-Command Get-ArcItemNames -ErrorAction SilentlyContinue) -and
            [bool](Get-Command Test-ArcVaultUnlocked -ErrorAction SilentlyContinue))
}

function Find-KeystoneArcRoot {
    # ARC is opt-in: only the path configured in Integrations
    # (config\keystone.local.json Arc.Enabled + Arc.Path) or KEYSTONE_ARC_PATH.
    # No search of ARC_PATH, sibling folders or the user profile.
    [CmdletBinding()]
    param()
    $configured = Get-KeystoneConfiguredArcPath
    if (-not $configured) { return $null }
    try {
        $full = [IO.Path]::GetFullPath($configured)
        if (Get-KeystoneArcFlavor -ArcRoot $full) { return $full }
    } catch { }
    return $null
}

function Get-KeystoneArcRequiredFiles {
    [CmdletBinding()]
    param([string]$ArcRoot)
    # Read ARC's declared library names. Different ARC releases can ship
    # different sets: never insist on Keystone's preferred STARK version.
    if (-not $ArcRoot) {
        # Fixed current-ARC reference, useful for regression tests only.
        return @(
            'lib/00-logging.ps1','lib/00-core.ps1','lib/01-storage.ps1',
            'lib/02-cac.ps1','lib/03-totp-core.ps1','lib/03-totp-recovery.ps1',
            'lib/03-totp-setup.ps1','lib/04-wincred.ps1','lib/05-update.ps1',
            'lib/06-ui.ps1','lib/07-cli.ps1','lib/08-gui.ps1',
            'lib/09-integrity.ps1','lib/10-stark.ps1'
        )
    }
    $pmPath = Join-Path $ArcRoot 'pm.ps1'
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

function Get-KeystoneArcMissingFiles {
    [CmdletBinding()]
    param([string]$ArcRoot)
    if (-not $ArcRoot) { return @() }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-KeystoneArcRequiredFiles -ArcRoot $ArcRoot)) {
        if (-not (Test-Path -LiteralPath (Join-Path $ArcRoot $name) -PathType Leaf)) {
            [void]$missing.Add($name)
        }
    }
    return @($missing.ToArray())
}

function Test-KeystoneArcHelpersAvailable {
    [CmdletBinding()]
    param()
    if (Test-KeystoneArc5HelpersAvailable) { return $true }
    $unlock = [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
    $stark = [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue)
    $finder = [bool](Get-Command Find-VaultRows -ErrorAction SilentlyContinue)
    $vault = [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue)
    $decrypt = [bool](Get-Command Unprotect-SecretText -ErrorAction SilentlyContinue)
    # Older ARC builds may lack the optional STARK helper, yet retain all
    # vault APIs needed to decrypt an item. Do not require STARK by name.
    return ($unlock -and ($stark -or ($decrypt -and ($finder -or $vault))))
}

function Get-KeystoneArcHelperDiagnostics {
    return [pscustomobject]@{
        arc5 = [bool](Test-KeystoneArc5HelpersAvailable)
        unlock = [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
        stark = [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue)
        find = [bool](Get-Command Find-VaultRows -ErrorAction SilentlyContinue)
        vault = [bool](Get-Command Get-LiveVault -ErrorAction SilentlyContinue)
        decrypt = [bool](Get-Command Unprotect-SecretText -ErrorAction SilentlyContinue)
    }
}

function Import-KeystoneArcSession {
    [CmdletBinding()]
    param([switch]$Quiet)
    # Never source pm.ps1 again once the ARC functions have been loaded;
    # reloading resets the vault's CAC/TOTP in-memory state.
    if (Test-KeystoneArcHelpersAvailable) {
        $script:KeystoneArcLoaded = $true
        $script:KeystoneArcErrorCode = ''
        $script:KeystoneArcLastError = ''
        if (-not $script:KeystoneArcFlavor) { $script:KeystoneArcFlavor = $(if (Test-KeystoneArc5HelpersAvailable) { 'v5' } else { 'legacy' }) }
        if (-not $script:KeystoneArcModule) {
            $name = if ($script:KeystoneArcFlavor -eq 'v5') { 'Test-ArcVaultUnlocked' } else { 'Ensure-VaultUnlocked' }
            $command = Get-Command $name -ErrorAction SilentlyContinue
            if ($command -and $command.Module) { $script:KeystoneArcModule = $command.Module }
        }
        return $true
    }
    if (Get-Module -Name KeystoneArc -ErrorAction SilentlyContinue) {
        $script:KeystoneArcErrorCode = 'ARC_HELPERS_UNAVAILABLE'
        $script:KeystoneArcLastError = 'ARC module was loaded, but required vault helpers are missing. Verify ARC installation and restart Keystone.'
        return $false
    }
    $arcRoot = Find-KeystoneArcRoot
    if (-not $arcRoot) {
        $script:KeystoneArcErrorCode = 'ARC_NOT_FOUND'
        $script:KeystoneArcLastError = 'ARC was not found. Set ARC_PATH to the ARC folder (the one containing lib\Arc.ps1).'
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
    $script:KeystoneArcRoot = $arcRoot
    $script:KeystoneArcFlavor = Get-KeystoneArcFlavor -ArcRoot $arcRoot
    if ($script:KeystoneArcFlavor -eq 'v5') { return (Import-KeystoneArc5 -ArcRoot $arcRoot -Quiet:$Quiet) }
    $script:KeystoneArcMissingModules = @(Get-KeystoneArcMissingFiles -ArcRoot $arcRoot)
    if ($script:KeystoneArcMissingModules.Count -gt 0) {
        $script:KeystoneArcErrorCode = 'ARC_MISSING_MODULES'
        $script:KeystoneArcLastError = 'ARC installation is incomplete. Missing libraries: ' + ($script:KeystoneArcMissingModules -join ', ') + '. Update the full ARC repository rather than copying pm.ps1 alone.'
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
    try {
        $pm = Join-Path $arcRoot 'pm.ps1'
        # Like Cascade, import all of ARC's commands from a single dynamic module.
        # A child PowerShell process cannot inherit ARC's unlocked session.
        $module = New-Module -Name KeystoneArc -ScriptBlock {
            param([string]$PmPath)
            $ErrorActionPreference = 'Continue'
            . $PmPath
            Export-ModuleMember -Function * -Alias * -ErrorAction SilentlyContinue
        } -ArgumentList $pm
        Import-Module -ModuleInfo $module -Global -ErrorAction Stop -WarningAction SilentlyContinue
        $script:KeystoneArcModule = $module
        if (-not (Test-KeystoneArcHelpersAvailable)) {
            $script:KeystoneArcErrorCode = 'ARC_HELPERS_UNAVAILABLE'
            $script:KeystoneArcLastError = 'ARC imported but required helpers are missing. Check Arc lib modules and use the diagnostics in Keystone Integrations.'
            if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
            return $false
        }
        $script:KeystoneArcLoaded = $true
        $script:KeystoneArcErrorCode = ''
        $script:KeystoneArcLastError = ''
        if (-not $Quiet) { Write-Host '[+] ARC module loaded into Keystone host process.' -ForegroundColor Green }
        return $true
    } catch {
        # ARC's loader throws "ARC load incomplete (N error(s))" if a
        # library cannot initialize. Classify it without forwarding raw error
        # messages, tokens, or vault data to the browser.
        $kind = $_.Exception.GetType().Name
        if ($_.Exception.Message -match 'ARC load incomplete') {
            $script:KeystoneArcErrorCode = 'ARC_LIBRARY_INITIALIZATION_FAILED'
            $script:KeystoneArcLastError = 'ARC pm.ps1 reported one or more library initialization failures. Open ARC itself and inspect its local error log, then restart Keystone.'
        } else {
            $script:KeystoneArcErrorCode = 'ARC_IMPORT_EXCEPTION'
            $script:KeystoneArcLastError = 'ARC import failed (' + $kind + '). Open ARC directly to inspect its local diagnostics. Keystone did not modify the vault.'
        }
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
}

function Import-KeystoneArc5 {
    # Load ARC 5's engine once into one dynamic module, so ARC's script-scoped
    # session state lives in one place and its functions are visible globally.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArcRoot,[switch]$Quiet)
    $loader = Join-Path (Join-Path $ArcRoot 'lib') 'Arc.ps1'
    $script:KeystoneArcMissingModules = @()
    try {
        $module = New-Module -Name KeystoneArc -ScriptBlock {
            param([string]$LoaderPath)
            $ErrorActionPreference = 'Stop'
            . $LoaderPath
            Export-ModuleMember -Function * -ErrorAction SilentlyContinue
        } -ArgumentList $loader
        Import-Module -ModuleInfo $module -Global -ErrorAction Stop -WarningAction SilentlyContinue
        $script:KeystoneArcModule = $module
    } catch {
        $script:KeystoneArcErrorCode = 'ARC_LIBRARY_INITIALIZATION_FAILED'
        $script:KeystoneArcLastError = 'ARC 5 lib\Arc.ps1 failed to load (' + $_.Exception.GetType().Name + '). Update the complete ARC repository, then restart Keystone.'
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
    if (-not (Test-KeystoneArc5HelpersAvailable)) {
        $script:KeystoneArcErrorCode = 'ARC_HELPERS_UNAVAILABLE'
        $script:KeystoneArcLastError = 'ARC 5 loaded but its integration functions (Unlock-ArcVaultInteractive, Get-ArcSecret, Get-ArcItemNames) are missing. Update ARC.'
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
    $script:KeystoneArcLoaded = $true
    $script:KeystoneArcErrorCode = ''
    $script:KeystoneArcLastError = ''
    if (-not $Quiet) { Write-Host '[+] ARC 5 engine loaded into Keystone host process.' -ForegroundColor Green }
    return $true
}

function Test-KeystoneArcVaultUnlocked {
    [CmdletBinding()]
    param()
    if (Test-KeystoneArc5HelpersAvailable) {
        try { return [bool](Test-ArcVaultUnlocked) } catch { return $false }
    }
    if (-not (Test-KeystoneArcHelpersAvailable)) { return $false }
    $module = $script:KeystoneArcModule
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

function Initialize-KeystoneArcAuthentication {
    [CmdletBinding()]
    param([switch]$SkipUnlock,[switch]$Quiet)
    if (-not (Get-KeystoneConfiguredArcPath)) {
        return [pscustomobject]@{ Found = $false; Loaded = $false; Unlocked = $false; Configured = $false; Message = 'ARC is not configured.' }
    }
    if (-not (Import-KeystoneArcSession -Quiet:$Quiet)) {
        return [pscustomobject]@{
            Found = [bool](Find-KeystoneArcRoot); Loaded = $false; Unlocked = $false
            Message = $script:KeystoneArcLastError
        }
    }
    if (-not $SkipUnlock -and -not (Test-KeystoneArcVaultUnlocked)) {
        if (-not $Quiet) {
            Write-Host ''
            Write-Host '[*] ARC authentication: complete the standard CAC + TOTP steps in this PowerShell window.' -ForegroundColor Cyan
            Write-Host '[*] You can cancel to launch Keystone without ARC; env credentials will still work.' -ForegroundColor DarkGray
        }
        try {
            # This is called BEFORE starting the listener, never on an HTTP request.
            # The prompts (CAC PIN or passphrase, then authenticator) are ARC's own.
            $unlocked = if (Test-KeystoneArc5HelpersAvailable) { [bool](Unlock-ArcVaultInteractive) } else { [bool](Ensure-VaultUnlocked) }
            if (-not $unlocked) { $script:KeystoneArcLastError = 'ARC authentication was cancelled or declined.' }
        } catch {
            $script:KeystoneArcLastError = 'ARC unlock failed (' + $_.Exception.GetType().Name + ').'
        }
    }
    $ready = Test-KeystoneArcVaultUnlocked
    if ($ready) {
        $script:KeystoneArcLastError = ''
        if (-not $Quiet) { Write-Host '[+] ARC vault unlocked in the Keystone host process.' -ForegroundColor Green }
    } elseif (-not $Quiet) {
        Write-Warning 'ARC is locked. Restart Keystone and complete CAC/TOTP, or use an approved environment credential.'
    }
    return [pscustomobject]@{
        Found = $true; Loaded = $true; Unlocked = [bool]$ready
        Message = $(if ($ready) { 'ARC is unlocked.' } else { $script:KeystoneArcLastError })
    }
}

function Convert-KeystoneArcVaultRows {
    # ARC sometimes returns an ArrayList with an extra unary-comma wrapper.
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

function Get-KeystoneArcServiceNames {
    [CmdletBinding()]
    param()
    if (-not (Test-KeystoneArcVaultUnlocked)) { return @() }
    if (Test-KeystoneArc5HelpersAvailable) {
        try {
            return @(@(Get-ArcItemNames) | ForEach-Object { [string]$_.Service } |
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
    foreach ($row in (Convert-KeystoneArcVaultRows -InputObject $catalog)) {
        $name = [string]$row.Service
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$names.Add($name) }
    }
    return @($names.ToArray() | Sort-Object -Unique)
}

function Get-KeystoneArcConnectionStatus {
    [CmdletBinding()]
    param()
    $configured = Get-KeystoneConfiguredArcPath
    $root = Find-KeystoneArcRoot
    $loaded = Test-KeystoneArcHelpersAvailable
    $unlocked = Test-KeystoneArcVaultUnlocked
    $names = @()
    if ($unlocked) { $names = @(Get-KeystoneArcServiceNames) }
    $bindings = @()
    foreach ($purpose in @('GitHub','GitLab','GenAi')) {
        $item = Get-KeystoneArcItemName -Provider $purpose
        $envName = switch ($purpose) {
            'GitHub' { 'GITHUB_TOKEN' }
            'GitLab' { 'GITLAB_TOKEN' }
            'GenAi' { 'GENAI_TOKEN' }
        }
        $envPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))
        if ($purpose -eq 'GenAi') {
            $envPresent = $envPresent -or -not [string]::IsNullOrWhiteSpace($env:KEYSTONE_AI_TOKEN)
        }
        $present = [bool]($unlocked -and ($names -contains $item))
        $bindings += [pscustomobject]@{
            provider = $purpose; item = $item
            configured = [bool]($envPresent -or $present)
            source = $(if ($envPresent) { 'environment' } elseif ($present) { 'arc' } else { 'none' })
            arcItemFound = $present
        }
    }
    return [pscustomobject]@{
        arcFound = [bool]$root
        arcLoaded = [bool]$loaded
        arcUnlocked = [bool]$unlocked
        arcPath = $(if ($root) { $root } else { '' })
        arcVersion = $(if ($loaded -and (Test-KeystoneArc5HelpersAvailable)) { '5' } elseif ($loaded) { 'legacy' } elseif ($root) { $(if ((Get-KeystoneArcFlavor -ArcRoot $root) -eq 'v5') { '5' } else { 'legacy' }) } else { '' })
        code = $(if (-not $configured) { 'ARC_NOT_CONFIGURED' } elseif ($loaded) { '' } elseif ($script:KeystoneArcErrorCode) { $script:KeystoneArcErrorCode } else { 'ARC_NOT_LOADED' })
        missingModules = @($script:KeystoneArcMissingModules)
        helpers = Get-KeystoneArcHelperDiagnostics
        configured = [bool]$configured
        message = $(if (-not $configured) { 'ARC is not configured. It is optional: enable it in Integrations with the ARC folder path.' }
                    elseif ($loaded -and $unlocked) { 'ARC is unlocked.' }
                    elseif ($loaded) { 'ARC loaded but locked. Restart Keystone and complete CAC + TOTP in its console.' }
                    elseif ($script:KeystoneArcLastError) { $script:KeystoneArcLastError }
                    elseif (-not $root) { 'ARC not found. Set ARC_PATH to the ARC folder (the one containing lib\Arc.ps1).' }
                    else { 'ARC was located but could not be loaded. Check the Keystone console and ARC installation.' })
        integrations = @($bindings)
        # Only service names, never usernames, passwords or API keys.
        itemNames = @($names)
    }
}

function Get-KeystoneArcSecretByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    # Never prompt for CAC/TOTP as a side effect of a browser request.
    if (-not (Test-KeystoneArcVaultUnlocked)) { return $null }
    if ($ServiceName.Length -gt 100) { return $null }
    if (Test-KeystoneArc5HelpersAvailable) {
        # Get-ArcSecret throws when the item is missing or ambiguous; the reason is
        # recorded without the secret and the caller reports ARC_ITEM_UNREADABLE.
        try {
            $value = Get-ArcSecret -Service $ServiceName
            if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        } catch {
            $reason = [string]$_.Exception.Message
            $script:KeystoneArcLastError = if ($reason -match 'items named') { "ARC has more than one item named '$ServiceName'. Rename one in ARC." } else { "ARC item '$ServiceName' could not be read." }
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
            # Fall back to the core ARC vault APIs if this optional helper
            # is unavailable for a particular item or ARC release.
        }
    }
    $row = $null
    if (Get-Command Find-VaultRows -ErrorAction SilentlyContinue) {
        try {
            $hits = Find-VaultRows -Name $ServiceName
            foreach ($hit in (Convert-KeystoneArcVaultRows -InputObject $hits)) {
                if ([string]$hit.Service -eq $ServiceName) { $row = $hit; break }
            }
        } catch { }
    }
    if (-not $row -and (Get-Command Get-LiveVault -ErrorAction SilentlyContinue)) {
        try {
            $hits = Get-LiveVault
            foreach ($hit in (Convert-KeystoneArcVaultRows -InputObject $hits)) {
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
    # Core ARC compatibility: legacy DPAPI SecureString payloads.
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

function Test-KeystoneArcAvailable {
    return [bool](Find-KeystoneArcRoot)
}

function Get-KeystoneArcCredential {
    # Token for a provider from the configured ARC vault, or a coded error that
    # says exactly why not. Never prompts: unlock happens at startup only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('GitHub','GitLab','GenAi')][string]$Provider)
    $name = Get-KeystoneArcItemName -Provider $Provider
    $status = Get-KeystoneArcConnectionStatus
    if (-not $status.arcFound) { throw "ARC_NOT_FOUND|$($status.message)" }
    if (-not $status.arcLoaded) {
        $reason = if ($status.message) { [string]$status.message } else { 'ARC module could not be loaded.' }
        throw "ARC_UNAVAILABLE|$reason"
    }
    if (-not $status.arcUnlocked) {
        throw 'ARC_LOCKED|ARC is configured but locked. Restart Keystone and complete the ARC unlock in its PowerShell window.'
    }
    $catalogNames = @($status.itemNames)
    if ($catalogNames.Count -gt 0 -and $name -notin $catalogNames) {
        throw "ARC_ITEM_MISSING|ARC vault has no item named '$name' for $Provider. Choose an existing item in Integrations."
    }
    $token = Get-KeystoneArcSecretByName -ServiceName $name
    if (-not $token) {
        throw "ARC_ITEM_UNREADABLE|ARC item '$name' for $Provider was missing, empty, ambiguous, or could not be read. Check it in ARC."
    }
    Write-KeystoneLog -Level INFO -Message "Credential source for $($Provider): ARC item '$name' (value not logged)."
    return $token
}
