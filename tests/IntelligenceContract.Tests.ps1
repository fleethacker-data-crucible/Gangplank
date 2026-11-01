#Requires -Version 5.1
# The shared AI module contract (docs/SHARED-AI-MODULE.md). Core/Intelligence.ps1 is copied into
# sibling products, so what it needs from the host must be known and must not grow silently:
#   - it names its version, and the guide quotes the same version;
#   - the host functions it calls are exactly the documented list;
#   - it knows nothing of Gangplank's session, providers or UI.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "FAILED: $Message" } }

$file = Join-Path $root 'Core\Intelligence.ps1'
$text = [IO.File]::ReadAllText($file)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
Assert (@($errors).Count -eq 0) 'Core/Intelligence.ps1 must parse'

# The version, in the file and in the guide.
Assert ($text -match '(?m)^# Shared module\. Gangplank Intelligence, version (\d+\.\d+\.\d+)') 'The module must name its version in a header line'
$version = $Matches[1]
$guide = [IO.File]::ReadAllText((Join-Path $root 'docs\SHARED-AI-MODULE.md'))
Assert ($guide.Contains("version $version")) "docs/SHARED-AI-MODULE.md must quote version $version"

# The host functions it calls (everything named *-Gangplank* that the file does not define itself).
$defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$called = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-Gangplank' } | Sort-Object -Unique)
$needs = @($called | Where-Object { $_ -notin $defined })
$expected = @(
    'ConvertFrom-GangplankApiResponse','Get-GangplankAiToken','Get-GangplankCredentialStatus','Get-GangplankEnv',
    'Get-GangplankEnvironmentCredential','Get-GangplankLocalSettings','Get-GangplankProviderErrorCode','Get-GangplankSafeUrl',
    'Get-GangplankStoredCredential','Invoke-GangplankHttpRequest','Save-GangplankLocalSettings','Write-GangplankAudit'
) | Sort-Object
Assert (($needs -join ',') -eq ($expected -join ',')) ("The host functions the module needs changed.`n  needs:    " + ($needs -join ', ') + "`n  expected: " + ($expected -join ', ') + "`n  Update the list in this test and in docs/SHARED-AI-MODULE.md, and bump the version.")
foreach ($name in $expected) { Assert ($guide.Contains($name)) "The guide must document the host function $name" }

# Nothing of Gangplank's session, providers or screens leaks into the shared file.
foreach ($forbidden in @('GangplankApp','ProviderObj','ProjectPath','BaselineSha','Start-GangplankJob','Send-GangplankJson','LazaretteBridge')) {
    Assert (-not $text.Contains($forbidden)) "Core/Intelligence.ps1 must not refer to $forbidden"
}

Write-Host "Shared AI module contract (version $version, $($expected.Count) host functions) passed." -ForegroundColor Green
