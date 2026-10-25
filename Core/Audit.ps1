#Requires -Version 5.1
# ============================================================
#  Core/Audit.ps1 - local write audit (JSON lines)
#  One line per remote write or credential/setting change: what, where, when.
#  Never file contents, tokens, or response bodies.
# ============================================================

$script:KeystoneAuditPath = $null

function Get-KeystoneAuditPath {
    if ($script:KeystoneAuditPath) { return $script:KeystoneAuditPath }
    $dir = if ($script:KeystoneLogDir) { $script:KeystoneLogDir } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs' }
    return (Join-Path $dir 'audit.jsonl')
}

function Write-KeystoneAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Action,[hashtable]$Data = @{})
    $entry = [ordered]@{ time = (Get-Date).ToUniversalTime().ToString('o'); action = $Action; user = [Environment]::UserName }
    foreach ($k in $Data.Keys) {
        if ($k -match '(?i)token|secret|password|content') { continue }   # never, even by mistake
        $entry[$k] = $Data[$k]
    }
    try {
        $path = Get-KeystoneAuditPath
        $dir = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::AppendAllText($path, (($entry | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-KeystoneLog -Level WARN -Message "Audit entry could not be written: $Action"
    }
}

function Get-KeystoneAuditEntries {
    [CmdletBinding()]
    param([ValidateRange(1,500)][int]$Last = 50)
    $path = Get-KeystoneAuditPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $path -Tail $Last -Encoding UTF8)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($l in $lines) { try { [void]$out.Add(($l | ConvertFrom-Json)) } catch { } }
    $arr = $out.ToArray(); [array]::Reverse($arr)
    return @($arr)
}
