#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Core\SmartSave.ps1')
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
$empty = New-KeystoneSmartMessage
Assert-True (-not $empty.HasChanges) 'Empty changes should not create a commit'
$one = New-KeystoneSmartMessage -Added @('src/new.ps1')
Assert-True ($one.Title -match '^feat\(src\):') 'Added file should have conventional title'
$multi = New-KeystoneSmartMessage -Modified @('src/a.ps1','docs/readme.md') -Deleted @('old.txt')
Assert-True ($multi.Files.Count -eq 3) 'Expected all changed files'
$ai = New-KeystoneSmartMessage -Modified @('src/a.ps1') -AiSuggestion 'fix(src): correct request parsing'
Assert-True ($ai.Source -eq 'ai') 'Valid AI title should be accepted'
$bad = New-KeystoneSmartMessage -Modified @('src/a.ps1') -AiSuggestion ('x' * 101)
Assert-True ($bad.Source -eq 'local') 'Invalid AI title must fall back'
Write-Host 'SmartSave checks passed'
