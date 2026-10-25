#Requires -Version 5.1
# ============================================================
#  Core/Logging.ps1  - structured console + file logging
# ============================================================

$script:GangplankLogDir = $null
$script:GangplankLogFile = $null
$script:GangplankLogLevel = "INFO"   # DEBUG | INFO | WARN | ERROR

function Initialize-GangplankLogging {
    param(
        [string]$LogDir,
        [ValidateSet("DEBUG","INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    if (-not $LogDir) {
        $root = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        # Prefer tool root/Logs
        $candidate = Join-Path (Split-Path $PSScriptRoot -Parent) "Logs"
        if (-not (Test-Path $candidate)) {
            $candidate = Join-Path (Get-Location).Path "Logs"
        }
        $LogDir = $candidate
    }
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $script:GangplankLogDir = $LogDir
    $day = Get-Date -Format "yyyyMMdd"
    $script:GangplankLogFile = Join-Path $LogDir ("gangplank-{0}.log" -f $day)
    $script:GangplankLogLevel = $Level
    Write-GangplankLog -Level INFO -Message "Logging initialized -> $($script:GangplankLogFile)"
}

function Write-GangplankLog {
    param(
        [ValidateSet("DEBUG","INFO","WARN","ERROR")]
        [string]$Level = "INFO",
        [Parameter(Mandatory)]
        [string]$Message,
        [object]$Data = $null
    )
    $order = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    if ($order[$Level] -lt $order[$script:GangplankLogLevel]) { return }

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[{0}] [{1}] {2}" -f $stamp, $Level.PadRight(5), $Message
    if ($null -ne $Data) {
        try {
            $json = $Data | ConvertTo-Json -Compress -Depth 4 -ErrorAction SilentlyContinue
            if ($json) { $line = "$line | $json" }
        } catch { }
    }

    $color = switch ($Level) {
        "DEBUG" { "DarkGray" }
        "INFO"  { "Gray" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host $line -ForegroundColor $color

    if ($script:GangplankLogFile) {
        try {
            Add-Content -LiteralPath $script:GangplankLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Write-GangplankError {
    param(
        [Parameter(Mandatory)]
        $ErrorRecord,
        [string]$Context = ""
    )
    $msg = if ($Context) { "$Context :: $($ErrorRecord.Exception.Message)" } else { $ErrorRecord.Exception.Message }
    Write-GangplankLog -Level ERROR -Message $msg -Data @{
        Type       = $ErrorRecord.Exception.GetType().FullName
        Script     = $ErrorRecord.InvocationInfo.ScriptName
        Line       = $ErrorRecord.InvocationInfo.ScriptLineNumber
        Category   = "$($ErrorRecord.CategoryInfo.Category)"
    }
}
