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

function Test-KeystoneArcHelpersAvailable {
    return [bool](Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) -and
           [bool](Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue)
}

function Import-KeystoneArcSession {
    [CmdletBinding()]
    param([switch]$Quiet)
    # Do not reload an ARC module: doing so resets its in-memory authentication.
    if (Test-KeystoneArcHelpersAvailable) {
        $script:KeystoneArcLoaded = $true
        if (-not $script:KeystoneArcModule) {
            $command = Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue
            if ($command -and $command.Module) { $script:KeystoneArcModule = $command.Module }
        }
        return $true
    }
    if (Get-Module -Name KeystoneArc -ErrorAction SilentlyContinue) {
        $script:KeystoneArcLastError = 'ARC module exists but expected functions are not exported.'
        return $false
    }
    $arcRoot = Find-KeystoneArcRoot
    if (-not $arcRoot) {
        $script:KeystoneArcLastError = 'ARC pm.ps1 was not found next to Keystone or in ARC_PATH.'
        if (-not $Quiet) { Write-Warning $script:KeystoneArcLastError }
        return $false
    }
    try {
        $pm = Join-Path $arcRoot 'pm.ps1'
        $module = New-Module -Name KeystoneArc -ScriptBlock {
            param([string]$PmPath)
            $ErrorActionPreference = 'Continue'
            . $PmPath
            Export-ModuleMember -Function * -Alias * -ErrorAction SilentlyContinue
        } -ArgumentList $pm
        Import-Module -ModuleInfo $module -Global -WarningAction SilentlyContinue
        if (-not (Test-KeystoneArcHelpersAvailable)) {
            $script:KeystoneArcLastError = 'ARC loaded, but Get-PmStarkApiKey/Ensure-VaultUnlocked were unavailable.'
            return $false
        }
        $script:KeystoneArcRoot = $arcRoot
        $script:KeystoneArcModule = $module
        $script:KeystoneArcLoaded = $true
        $script:KeystoneArcLastError = ''
        if (-not $Quiet) { Write-Host '[+] ARC module loaded into Keystone host process.' -ForegroundColor Green }
        return $true
    } catch {
        # Log exception class only; ARC exceptions can include operational details.
        $script:KeystoneArcLastError = 'ARC import failed (' + $_.Exception.GetType().Name + ').'
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
        message = $(if (-not $root) { 'ARC not found. Set ARC_PATH to the folder containing pm.ps1.' }
                    elseif (-not $loaded) { 'ARC found but not loaded.' }
                    elseif (-not $unlocked) { 'ARC locked. Restart Keystone and authenticate with CAC + TOTP in its console.' }
                    else { 'ARC is unlocked.' })
        integrations = @($bindings)
        # Only service names, never usernames, passwords or API keys.
        itemNames = @($names)
    }
}

function Get-KeystoneArcSecretByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServiceName)
    # Prevent CAC/TOTP dialogs inside HttpListener request handlers.
    if (-not (Test-KeystoneArcVaultUnlocked)) {
        return $null
    }
    $key = $null
    try {
        $key = Get-PmStarkApiKey -VaultName $ServiceName
        if ($key -is [string] -and -not [string]::IsNullOrWhiteSpace($key)) {
            return $key.Trim()
        }
    } catch {
        # The caller uses the catalog/status for a nonsecret error message.
        return $null
    } finally { $key = $null }
    return $null
}

function Test-KeystoneArcAvailable {
    return [bool](Find-KeystoneArcRoot)
}
