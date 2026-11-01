#Requires -Version 5.1
# The legacy full-folder upload is retired: nothing exports it, no provider can do it, and no
# script or document tells anyone to use it. The classic text menu stays (pull, Smart Save,
# review request), so it must still parse and call only functions the module exports.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Gangplank.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'TestIsolation.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$module = Get-Module Gangplank
Assert (-not (Get-Command Invoke-GangplankPush -ErrorAction SilentlyContinue)) 'Invoke-GangplankPush must not be available'
Assert ('Invoke-GangplankPush' -notin @($module.ExportedFunctions.Keys)) 'Invoke-GangplankPush must not be exported'
& $module {
    function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }
    foreach ($name in @('Invoke-GangplankPush','New-GangplankPushActions','Split-GangplankPushBatches')) {
        Assert (-not (Get-Command $name -ErrorAction SilentlyContinue)) "$name must be gone"
    }
    foreach ($type in @([GitHubProvider],[GitLabProvider])) {
        Assert ($null -eq $type.GetMethod('PushFolder')) ($type.Name + ' must not have PushFolder')
    }
    # The Smart Save building blocks the browser and the menu use are still there.
    foreach ($m in @('CreateBlob','CreateTree','CreateCommit','CreateOrUpdateBranchRef','CreatePullRequest','GetBranches','DownloadArchive')) {
        Assert ($null -ne [GitHubProvider].GetMethod($m)) "GitHubProvider.$m must remain"
    }
    foreach ($m in @('CreateMergeRequest','GetBranches','DownloadArchive')) {
        Assert ($null -ne [GitLabProvider].GetMethod($m)) "GitLabProvider.$m must remain"
    }
}

# No script, launcher or document refers to the retired upload as something to use.
$retired = '(?i)Invoke-GangplankPush|PushFolder|ALLOW_LEGACY_BULK_UPLOAD|Share my folder'
$hits = @()
foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1,*.psm1,*.bat,*.md,*.mjs,*.cjs,*.js,*.yml | Where-Object { $_.FullName -notmatch '\\(\.git|node_modules|_archive|Logs)\\' -and $_.Name -ne 'LegacyRetired.Tests.ps1' -and $_.FullName -notmatch '\\docs\\(RECOVERY-REPORT|ENTERPRISE-ROADMAP|ROADMAP)\.md$' })) {
    if ([IO.File]::ReadAllText($f.FullName) -match $retired) { $hits += $f.FullName.Substring($root.Length) }
}
Assert ($hits.Count -eq 0) ('The retired upload is still mentioned in: ' + ($hits -join ', '))

# The classic menu: parses, and calls only functions the module exports.
$menu = Join-Path $root 'Gangplank.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($menu,[ref]$tokens,[ref]$errors)
Assert (@($errors).Count -eq 0) ('Gangplank.ps1 must parse: ' + (@($errors | ForEach-Object Message) -join '; '))
$defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$called = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-Gangplank' } | Sort-Object -Unique)
$exported = @($module.ExportedFunctions.Keys)
$missing = @($called | Where-Object { $_ -notin $exported -and $_ -notin $defined })
Assert ($missing.Count -eq 0) ('The classic menu calls functions the module does not export: ' + ($missing -join ', '))
Assert ('Invoke-GangplankWorkspaceSave' -in $called) 'The classic menu saves through verified Smart Save'

Write-Host 'Legacy bulk upload retirement checks passed.' -ForegroundColor Green
