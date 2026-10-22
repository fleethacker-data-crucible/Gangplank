#Requires -Version 5.1
# Keystone -> ARC 3.x/4.x integration.
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

function Find-KeystoneArcRoot {
    [CmdletBinding()]
    param()
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($env:ARC_PATH,$env:ARC_ROOT,$env:ARC_HOME)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            [void]$candidates.Add($p.Trim().Trim('"').Trim("'"))
        }
    }
    # ArcBridge.ps1 lives in Keystone root; ARC normally lives NEXT TO Keystone.
    $root = $script:KeystoneArcBridgeRoot
    if (-not $root) { $root = (Get-Location).Path }
    try {
        [void]$candidates.Add((Join-Path (Split-Path $root -Parent) 'arc'))
        [void]$candidates.Add((Join-Path (Split-Path $root -Parent) 'Arc'))
    } catch { }
    if ($env:USERPROFILE) {
        [void]$candidates.Add((Join-Path $env:USERPROFILE 'Projects\arc'))
        [void]$candidates.Add((Join-Path $env:USERPROFILE 'arc'))
    }
    $visited = @{}
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if ($visited.ContainsKey($full.ToLowerInvariant())) { continue }
            $visited[$full.ToLowerInvariant()] = $true
            if (Test-Path -LiteralPath (Join-Path $full 'pm.ps1') -PathType Leaf) {
                return $full
            }
        } catch { }
    }
    return $null
}

function Get-KeystoneArcRequiredFiles {
    # These libraries are dot-sourced by ARC's own pm.ps1.
    # Report missing filenames, not filesystem contents or secret data.
    return @(
        'lib/00-logging.ps1','lib/00-core.ps1','lib/01-storage.ps1',
        'lib/02-cac.ps1','lib/03-totp-core.ps1','lib/03-totp-recovery.ps1',
        'lib/03-totp-setup.ps1','lib/04-wincred.ps1','lib/05-update.ps1',
        'lib/06-ui.ps1','lib/07-cli.ps1','lib/08-gui.ps1',
        'lib/09-integrity.ps1','lib/10-stark.ps1'
    )
}

function Get-KeystoneArcMissingFiles {
    [CmdletBinding()]
    param([string]$ArcRoot)
    if (-not $ArcRoot) { return @() }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-KeystoneArcRequiredFiles)) {
        if (-not (Test-Path -LiteralPath (Join-Path $ArcRoot $name) -PathType Leaf)) {
            [void]$missing.Add($name)
        }
    }
    return @($missing.ToArray())
}

function Test-KeystoneArcHelpersAvailable {
    [CmdletBinding()]
    param()
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
        if (-not $script:KeystoneArcModule) {
            $command = Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue
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
        $script:KeystoneArcLastError = 'ARC pm.ps1 was not found. Set ARC_PATH to the folder containing pm.ps1.'
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
    $script:KeystoneArcRoot = $arcRoot
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

function Test-KeystoneArcVaultUnlocked {
    [CmdletBinding()]
    param()
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
            # This is called BEFORE starting HttpListener, never on an HTTP request.
            $unlocked = [bool](Ensure-VaultUnlocked)
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

function Get-KeystoneArcServiceNames {
    [CmdletBinding()]
    param()
    if (-not (Test-KeystoneArcVaultUnlocked)) { return @() }
    $command = Get-Command Get-PmVaultNameCatalog -ErrorAction SilentlyContinue
    if (-not $command) { return @() }
    try {
        $catalog = Get-PmVaultNameCatalog
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($row in $catalog) {
            if ($row -is [System.Collections.IList] -and -not ($row -is [string])) {
                foreach ($nested in $row) {
                    if ($nested -and $nested.Service) { [void]$names.Add([string]$nested.Service) }
                }
            } elseif ($row -and $row.Service) {
                [void]$names.Add([string]$row.Service)
            }
        }
        return @($names.ToArray() | Sort-Object -Unique)
    } catch { return @() }
}

function Get-KeystoneArcConnectionStatus {
    [CmdletBinding()]
    param()
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
        code = $(if ($loaded) { '' } elseif ($script:KeystoneArcErrorCode) { $script:KeystoneArcErrorCode } else { 'ARC_NOT_LOADED' })
        missingModules = @($script:KeystoneArcMissingModules)
        helpers = Get-KeystoneArcHelperDiagnostics
        message = $(if ($loaded -and $unlocked) { 'ARC is unlocked.' }
                    elseif ($loaded) { 'ARC loaded but locked. Restart Keystone and complete CAC + TOTP in its console.' }
                    elseif ($script:KeystoneArcLastError) { $script:KeystoneArcLastError }
                    elseif (-not $root) { 'ARC pm.ps1 not found. Set ARC_PATH to the ARC project folder.' }
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
            foreach ($hit in $hits) {
                if ($hit -and [string]$hit.Service -eq $ServiceName) { $row = $hit; break }
            }
        } catch { }
    }
    if (-not $row -and (Get-Command Get-LiveVault -ErrorAction SilentlyContinue)) {
        try {
            foreach ($hit in (Get-LiveVault)) {
                if ($hit -and [string]$hit.Service -eq $ServiceName) { $row = $hit; break }
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
