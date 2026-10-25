#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$required=@(
 '.github/workflows/keystone-ci.yml','.github/workflows/prune-merged-branches.yml',
 '.gitignore','ArcBridge.ps1','Keystone.ps1','Keystone.psm1',
 'Start-KeystoneWeb.ps1','Launch-Keystone.bat','Launch-LocalDev.bat',
 'Core/AI.ps1','Core/Configuration.ps1','Core/Diff.ps1',
 'Core/Logging.ps1','Core/SmartSave.ps1','Core/Utils.ps1',
 'Core/Workspace.ps1','Core/Sentinel.ps1','Core/RepositoryInsights.ps1',
 'Providers/GitProviderBase.ps1','Providers/GitHubProvider.ps1','Providers/GitLabProvider.ps1',
 'config/keystone-config.json','README.md','LOCAL-DEV.md',
 'docs/ENTERPRISE-ROADMAP.md','docs/SECURITY-MODEL.md',
 'tests/Workspace.Tests.ps1','tests/SmartSave.Tests.ps1','tests/WebHost.Tests.ps1',
 'tests/ArcIntegration.Tests.ps1','tests/ArcCoreOnly.Tests.ps1',
 'tests/Arc5Contract.Tests.ps1','tests/Arc5Real.Tests.ps1','tests/ProviderSafety.Tests.ps1',
 'tests/Sentinel.Tests.ps1','tests/RepositoryInsights.Tests.ps1',
 'tests/BrowserSyntax.Tests.cjs','web/index.html','web/app.js','web/app.css','web/logo.svg','docs/keystone-logo.svg',
 'Core/HttpClient.ps1','Core/Credentials.ps1','Core/Audit.ps1',
 'Server/Http.ps1','Server/Routes.ps1','Server/Jobs.ps1','Server/JobWork.ps1','Server/Session.ps1','Server/WebHost.ps1',
 'dev/fake-github.mjs','dev/fake-github.test.mjs','dev/Start-LocalDev.ps1','tests/e2e/host.e2e.mjs','tests/e2e/browser.e2e.mjs','tests/Intelligence.Tests.ps1','Core/Intelligence.ps1','dev/fake-ai.mjs','tests/Credentials.Tests.ps1',
 'docs/ROADMAP.md','TechStack'
)
$missing=@($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
if($missing.Count -gt 0){throw ('Keystone critical files missing: '+($missing -join ', '))}
Write-Host ('Repository integrity passed: '+$required.Count+' required files present.') -ForegroundColor Green
