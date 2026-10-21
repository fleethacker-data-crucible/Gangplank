#Requires -Version 5.1
# ============================================================
#  ArcBridge.ps1
#  Reusable ARC vault bridge (Cascade pattern)
#  One process, one load. Never re-dot-source pm.ps1.
#  Integrators use pm.ps1 only - never pm.bat / launch-arc.bat.
#
#  Canonical ARC Service names (names only, never secrets):
#    gitmil      - GitLab PAT (web.git.mil)
#    github      - GitHub token
#    genapi      - GenAi / api.genai.mil
#    advana-api  - Grok / Advana Databricks
#  Discovery: ARC_PATH, ARC_ROOT, ARC_HOME, then sibling Projects\arc
# ============================================================

$script:KeystoneArcLoaded = $false
$script:KeystoneArcRoot   = $null

function Find-KeystoneArcRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($env:ARC_PATH, $env:ARC_ROOT, $env:ARC_HOME)) {
        if ($e) { [void]$candidates.Add($e.Trim().Trim('"').Trim("'")) }
    }
    # Sibling of tool root (Projects\Keystone -> Projects\arc)
    $toolRoot = $null
    try {
        if ($PSScriptRoot) {
            $toolRoot = Split-Path $PSScriptRoot -Parent   # if ArcBridge lives in tool root
            if ((Split-Path $PSScriptRoot -Leaf) -eq "Core" -or (Split-Path $PSScriptRoot -Leaf) -eq "Providers") {
                $toolRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            }
        }
    } catch { }
    if (-not $toolRoot) { $toolRoot = (Get-Location).Path }

    [void]$candidates.Add((Join-Path (Split-Path $toolRoot -Parent) "arc"))
    [void]$candidates.Add((Join-Path $toolRoot "..\arc"))
    if ($env:USERPROFILE) {
        [void]$candidates.Add((Join-Path $env:USERPROFILE "Projects\arc"))
        [void]$candidates.Add((Join-Path $env:USERPROFILE "arc"))
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try {
            $full = [IO.Path]::GetFullPath($c)
            if (Test-Path -LiteralPath (Join-Path $full "pm.ps1")) {
                return $full
            }
        } catch { continue }
    }
    return $null
}

function Import-KeystoneArcSession {
    param([switch]$Quiet)

    if ($script:KeystoneArcLoaded) {
        if ((Get-Command Get-LiveVault -ErrorAction SilentlyContinue) -or
            (Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue)) {
            if (-not $Quiet) { Write-KeystoneLog -Level DEBUG -Message "ARC already loaded in this process" }
            return $true
        }
    }

    $arcRoot = Find-KeystoneArcRoot
    if (-not $arcRoot) {
        if (-not $Quiet) { Write-KeystoneLog -Level WARN -Message "ARC not found on disk" }
        return $false
    }
    $script:KeystoneArcRoot = $arcRoot
    $pm = Join-Path $arcRoot "pm.ps1"

    try {
        # Dynamic module keeps $script: vault state alive (Cascade pattern)
        $mod = New-Module -Name "KeystoneArc" -ScriptBlock {
            param($PmPath)
            . $PmPath
        } -ArgumentList $pm

        Import-Module $mod -Global -Force
        $script:KeystoneArcLoaded = $true
        if (-not $Quiet) {
            Write-KeystoneLog -Level INFO -Message "ARC loaded from $arcRoot"
        }
        return $true
    } catch {
        if (-not $Quiet) {
            Write-KeystoneLog -Level ERROR -Message "ARC load failed: $($_.Exception.Message)"
        }
        return $false
    }
}

function Convert-KeystoneArcRows {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    if ($InputObject -is [System.Collections.IList] -and -not ($InputObject -is [string])) {
        for ($i = 0; $i -lt $InputObject.Count; $i++) {
            if ($null -ne $InputObject[$i]) { [void]$out.Add($InputObject[$i]) }
        }
        return @($out.ToArray())
    }
    if ($InputObject.PSObject.Properties.Name -contains "Service") {
        return @($InputObject)
    }
    return @($InputObject)
}

function Get-KeystoneArcSecretByName {
    param([Parameter(Mandatory)][string]$ServiceName)

    if (-not (Import-KeystoneArcSession -Quiet)) { return $null }

    # Prefer STARK helper used by Cascade
    if (Get-Command Get-PmStarkApiKey -ErrorAction SilentlyContinue) {
        try {
            $k = Get-PmStarkApiKey -VaultName $ServiceName
            if (-not [string]::IsNullOrWhiteSpace($k)) { return $k.Trim() }
        } catch {
            Write-KeystoneLog -Level DEBUG -Message "Get-PmStarkApiKey($ServiceName): $($_.Exception.Message)"
        }
    }

    $row = $null
    if (Get-Command Find-VaultRows -ErrorAction SilentlyContinue) {
        try {
            $hits = Convert-KeystoneArcRows (Find-VaultRows -Name $ServiceName)
            $row = $hits | Sort-Object { ([string]$_.Secret).Length } -Descending | Select-Object -First 1
        } catch { }
    }
    if (-not $row -and (Get-Command Get-LiveVault -ErrorAction SilentlyContinue)) {
        try {
            if (Get-Command Ensure-VaultUnlocked -ErrorAction SilentlyContinue) {
                [void](Ensure-VaultUnlocked)
            }
            $all = Convert-KeystoneArcRows (Get-LiveVault)
            $row = $all | Where-Object { [string]$_.Service -eq $ServiceName } | Select-Object -First 1
        } catch { }
    }
    if (-not $row) { return $null }

    $raw = [string]$row.Secret
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    if (Get-Command Unprotect-SecretText -ErrorAction SilentlyContinue) {
        try {
            $p = Unprotect-SecretText -Protected $raw
            if (-not [string]::IsNullOrWhiteSpace($p)) { return $p.Trim() }
        } catch { }
    }
    try {
        $ss = ConvertTo-SecureString $raw -ErrorAction Stop
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
            if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain.Trim() }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) | Out-Null
        }
    } catch {
        return $raw.Trim()
    }
    return $null
}

function Test-KeystoneArcAvailable {
    return [bool](Find-KeystoneArcRoot)
}
