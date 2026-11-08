#Requires -Version 5.1

# Lazarette Lite fallback: a Lite folder (LazaretteLite.psd1 marker + a
# lib\Lazarette.ps1 that defines only Lite's three functions) works through the
# same opt-in bridge as full Lazarette. Fake Lite only: no real Credential
# Manager, no real vault, no network. Separate process (CI runs each suite in
# its own).

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent

$temp = Join-Path ([IO.Path]::GetTempPath()) ('gangplank-lazarette-lite-' + [guid]::NewGuid().ToString('N'))

$saved = @{}
foreach ($n in @('GANGPLANK_LAZARETTE_PATH','LAZARETTE_PATH','GITHUB_TOKEN','GITLAB_TOKEN','GANGPLANK_LAZARETTE_ITEM_GitHub')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    [Environment]::SetEnvironmentVariable($n,$null)
}

function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

# The fake Lite loader, as lines. Lite's real lib\Lazarette.ps1 defines exactly
# three functions (Unlock-LazaretteVaultInteractive, Get-LazaretteSecret,
# Get-LazaretteItemNames) and deliberately has no Test-LazaretteVaultUnlocked.
$liteLoaderLines = @(
'$script:LiteRecords = @(',
'    [pscustomobject]@{ Service = ''github''; User = ''me''; Secret = ''fake-lite-github-token'' },',
'    [pscustomobject]@{ Service = ''gitlab''; User = ''me''; Secret = ''fake-lite-gitlab-token'' },',
'    [pscustomobject]@{ Service = ''data-platform-api''; User = ''me''; Secret = ''fake-lite-data-platform-token'' }',
')',
'function Unlock-LazaretteVaultInteractive { $global:LiteUnlockCalls += 1; return $true }',
'function Get-LazaretteItemNames {',
'    return @($script:LiteRecords | ForEach-Object { [pscustomobject]@{ Service = $_.Service; User = $_.User; Type = ''login''; Tags = @() } })',
'}',
'function Get-LazaretteSecret {',
'    param([Parameter(Mandatory)][string]$Service, [string]$User, [string]$Field)',
'    $hits = @($script:LiteRecords | Where-Object { $_.Service -ieq $Service })',
'    if ($hits.Count -ne 1) { throw "Lazarette Lite has no item ''$Service''." }',
'    return [string]$hits[0].Secret',
'}'
)

# A partial Lite loader: marker present, but Get-LazaretteSecret missing. Only
# Test-LazaretteVaultUnlocked is ever shimmed, and only for Lite.
$partialLoaderLines = @(
'function Unlock-LazaretteVaultInteractive { return $true }',
'function Get-LazaretteItemNames { return @() }'
)

# A full-Lazarette-shaped loader: no marker, all four functions.
$fullLoaderLines = @(
'$script:StubUnlocked = $false',
'function Test-LazaretteVaultUnlocked { return $script:StubUnlocked }',
'function Unlock-LazaretteVaultInteractive { $script:StubUnlocked = $true; return $true }',
'function Get-LazaretteItemNames { return @([pscustomobject]@{ Service = ''github''; User = ''me'' }) }',
'function Get-LazaretteSecret {',
'    param([Parameter(Mandatory)][string]$Service, [string]$User, [string]$Field)',
'    return ''fake-full-github-token''',
'}'
)

try {
    $bare = Join-Path $temp 'bare'
    [void](New-Item -ItemType Directory -Path (Join-Path $bare 'lib') -Force)

    $lite = Join-Path $temp 'lite'
    [void](New-Item -ItemType Directory -Path (Join-Path $lite 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path $lite 'LazaretteLite.psd1'), "# Marker only: identifies this fake folder as Lazarette Lite for the provider-kind check. Not a real manifest.`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path (Join-Path $lite 'lib') 'Lazarette.ps1'), ([string]::Join("`n", $liteLoaderLines)), (New-Object Text.UTF8Encoding($false)))

    $partial = Join-Path $temp 'partial-lite'
    [void](New-Item -ItemType Directory -Path (Join-Path $partial 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path $partial 'LazaretteLite.psd1'), "# Marker only.`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path (Join-Path $partial 'lib') 'Lazarette.ps1'), ([string]::Join("`n", $partialLoaderLines)), (New-Object Text.UTF8Encoding($false)))

    $full = Join-Path $temp 'full'
    [void](New-Item -ItemType Directory -Path (Join-Path $full 'lib') -Force)
    [IO.File]::WriteAllText((Join-Path (Join-Path $full 'lib') 'Lazarette.ps1'), ([string]::Join("`n", $fullLoaderLines)), (New-Object Text.UTF8Encoding($false)))

    Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
    . (Join-Path $PSScriptRoot 'TestIsolation.ps1')
    Initialize-Gangplank -LogLevel ERROR

    Assert (Test-GangplankLazaretteFolder -LazaretteRoot $lite) 'lib\Lazarette.ps1 must identify a Lite folder'
    Assert (-not (Test-GangplankLazaretteFolder -LazaretteRoot $bare)) 'A folder without lib\Lazarette.ps1 is not Lazarette or Lite'
    Assert ((Get-GangplankLazaretteProviderKind -LazaretteRoot $lite) -eq 'lite') 'Marker folder must report kind lite'
    Assert ((Get-GangplankLazaretteProviderKind -LazaretteRoot $full) -eq 'lazarette') 'Unmarked folder must report kind lazarette'
    Assert (-not (Get-GangplankLazaretteProviderKind -LazaretteRoot $bare)) 'Bare folder must report no kind'
    Assert (-not (Get-GangplankLazaretteProviderKind -LazaretteRoot '')) 'Empty root must report no kind'

    # Generic LAZARETTE_PATH must not enable Lite either.
    $env:LAZARETTE_PATH = $lite
    Assert (-not (Test-GangplankLazaretteConfigured)) 'LAZARETTE_PATH must not enable Lite'
    $env:LAZARETTE_PATH = $null

    # A partial Lite folder (marker present, Get-LazaretteSecret missing) is
    # rejected: only Test-LazaretteVaultUnlocked is ever shimmed for Lite.
    # This runs first: once the full Lite functions load, the session check
    # short-circuits and a partial loader could not be exercised in-process.
    $env:GANGPLANK_LAZARETTE_PATH = $partial
    Assert (-not (Import-GangplankLazaretteSession -Quiet)) 'Partial Lite engine must be rejected'
    Assert ((Get-GangplankLazaretteConnectionStatus).code -eq 'LAZARETTE_HELPERS_UNAVAILABLE') 'Partial Lite must be diagnosed as helpers unavailable'
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue

    # The Lite folder, via the explicit Gangplank path only.
    $env:GANGPLANK_LAZARETTE_PATH = $lite
    Assert ((Find-GangplankLazaretteRoot) -eq [IO.Path]::GetFullPath($lite)) 'GANGPLANK_LAZARETTE_PATH must enable Lite'
    $global:LiteUnlockCalls = 0
    Assert (Import-GangplankLazaretteSession -Quiet) 'Lite engine should load from lib\Lazarette.ps1'
    $status = Get-GangplankLazaretteConnectionStatus
    Assert ($status.lazaretteKind -eq 'lite') 'Status must report kind lite'
    Assert ($status.lazaretteVersion -eq 'lite') 'Status must report version lite, never 5'
    Assert ($status.lazaretteUnlocked) 'Lite has no lock: it must report unlocked without an unlock call'
    Assert ($global:LiteUnlockCalls -eq 0) 'Lite unlock must never be called (no prompt, no TOTP)'
    $state = Initialize-GangplankLazaretteAuthentication -Quiet
    Assert ($state.Unlocked -and $global:LiteUnlockCalls -eq 0) 'Startup auth must not prompt for Lite'
    Assert ((@($status.itemNames) -join ',') -eq 'data-platform-api,github,gitlab') 'Lite item names must come from Get-LazaretteItemNames'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'fake-lite-github-token') 'GitHub token must be read from Lite'
    Assert ((Get-GangplankToken -Provider GitLab) -eq 'fake-lite-gitlab-token') 'GitLab token must be read from Lite'
    Assert ((Get-GangplankLazaretteSecretByName -ServiceName 'data-platform-api') -eq 'fake-lite-data-platform-token') 'data-platform-api must be read from Lite'
    $json = (Get-GangplankLazaretteConnectionStatus) | ConvertTo-Json -Depth 8
    Assert ($json -notmatch 'fake-lite-') 'Connection status leaked a secret'
    $env:GITHUB_TOKEN = 'env-wins'
    Assert ((Get-GangplankToken -Provider GitHub) -eq 'env-wins') 'Approved environment credential should take precedence over Lite'
    $env:GITHUB_TOKEN = $null

    Write-Host 'Gangplank Lazarette Lite fallback passed.' -ForegroundColor Green
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n,$saved[$n]) }
    Remove-Module GangplankLazarette -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}