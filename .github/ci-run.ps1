# Copied from Lazarette .github/ci-run.ps1 (keep in sync).
# Runs one CI command and, when it fails, turns the interesting output lines into GitHub
# annotations (::error) so failures can be read from the PR checks page without the job log.
#   .github\ci-run.ps1 -Title 'cargo test' -Command 'cargo test --release' [-WorkingDirectory pdf-engine]
param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Command,
    [string]$WorkingDirectory = '',
    [int]$Tail = 60
)
$ErrorActionPreference = 'Continue'
function Out-Annotation([string]$T, [string]$Text) {
    # GitHub truncates one annotation at ~4 KB, so long output goes out as several numbered annotations.
    $t = $T -replace '[,:]', ' '
    $clean = $Text -replace "`r", ''
    $chunks = [Math]::Max(1, [Math]::Ceiling($clean.Length / 3500.0)); if ($chunks -gt 12) { $chunks = 12 }
    for ($i = 0; $i -lt $chunks; $i++) {
        $part = $clean.Substring($i * 3500, [Math]::Min(3500, $clean.Length - $i * 3500))
        $m = $part -replace '%', '%25' -replace "`n", '%0A'
        $title = if ($chunks -gt 1) { "{0} ({1}/{2})" -f $t, ($i + 1), $chunks } else { $t }
        Write-Host ("::error title={0}::{1}" -f $title, $m)
    }
}
if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
Write-Host "> $Command"
$lines = New-Object System.Collections.Generic.List[string]
& cmd.exe /d /s /c "$Command 2>&1" | ForEach-Object { $s = [string]$_; Write-Host $s; [void]$lines.Add($s) }
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    # Strip ANSI colour and send the whole output (chunked); the first error is usually the useful one.
    $show = (($lines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' }) -join "`n")
    if ($show.Length -gt 40000) { $show = $show.Substring(0, 40000) + "`n[... truncated]" }
    Out-Annotation ("{0} failed (exit {1})" -f $Title, $rc) $show
    exit $rc
}
exit 0
