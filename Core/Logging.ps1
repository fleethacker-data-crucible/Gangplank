#Requires -Version 5.1
# ============================================================
#  Core/Logging.ps1  - structured console + file logging
# ============================================================

$script:KeystoneLogDir = $null
$script:KeystoneLogFile = $null
$script:KeystoneLogLevel = "INFO"   # DEBUG | INFO | WARN | ERROR

function Initialize-KeystoneLogging {
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
    $script:KeystoneLogDir = $LogDir
    $day = Get-Date -Format "yyyyMMdd"
    $script:KeystoneLogFile = Join-Path $LogDir ("keystone-{0}.log" -f $day)
    $script:KeystoneLogLevel = $Level
    Write-KeystoneLog -Level INFO -Message "Logging initialized -> $($script:KeystoneLogFile)"
}

function Write-KeystoneLog {
    param(
        [ValidateSet("DEBUG","INFO","WARN","ERROR")]
        [string]$Level = "INFO",
        [Parameter(Mandatory)]
        [string]$Message,
        [object]$Data = $null
    )
    $order = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    if ($order[$Level] -lt $order[$script:KeystoneLogLevel]) { return }

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

    if ($script:KeystoneLogFile) {
        try {
            Add-Content -LiteralPath $script:KeystoneLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Write-KeystoneError {
    param(
        [Parameter(Mandatory)]
        $ErrorRecord,
        [string]$Context = ""
    )
    $msg = if ($Context) { "$Context :: $($ErrorRecord.Exception.Message)" } else { $ErrorRecord.Exception.Message }
    Write-KeystoneLog -Level ERROR -Message $msg -Data @{
        Type       = $ErrorRecord.Exception.GetType().FullName
        Script     = $ErrorRecord.InvocationInfo.ScriptName
        Line       = $ErrorRecord.InvocationInfo.ScriptLineNumber
        Category   = "$($ErrorRecord.CategoryInfo.Category)"
    }
}
