#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$required=@(
 '.github/workflows/gangplank-ci.yml','.github/workflows/prune-merged-branches.yml',
 '.gitignore','LazaretteBridge.ps1','Gangplank.ps1','Gangplank.psm1',
 'Start-Gangplank.ps1','Launch-Gangplank.bat','Launch-LocalDev.bat',
 'Core/AI.ps1','Core/Configuration.ps1','Core/Diff.ps1',
 'Core/Logging.ps1','Core/SmartSave.ps1','Core/Utils.ps1',
 'Core/Workspace.ps1','Core/Sentinel.ps1','Core/RepositoryInsights.ps1',
 'Providers/GitProviderBase.ps1','Providers/GitHubProvider.ps1','Providers/GitLabProvider.ps1',
 'config/gangplank-config.json','README.md','LOCAL-DEV.md',
 'docs/ENTERPRISE-ROADMAP.md','docs/SECURITY-MODEL.md',
 'tests/Workspace.Tests.ps1','tests/SmartSave.Tests.ps1','tests/WebHost.Tests.ps1',
 'tests/LazaretteIntegration.Tests.ps1','tests/LazaretteCoreOnly.Tests.ps1',
 'tests/TestIsolation.ps1','tests/LazaretteContract.Tests.ps1','tests/LazaretteReal.Tests.ps1','tests/LazaretteNames.Tests.ps1','tests/ProviderSafety.Tests.ps1',
 'tests/Sentinel.Tests.ps1','tests/RepositoryInsights.Tests.ps1',
 'tests/BrowserSyntax.Tests.cjs','web/index.html','web/app.js','web/app.css','web/logo.svg','web/shell.js','web/icons.js','web/vendor/fleet/fleet.css','web/favicon.ico','web/brand/icon-256.png','web/brand/emblem-dark.png','web/brand/emblem-light.png','tools/gen-icons.mjs','docs/gangplank-logo.svg',
 'Core/HttpClient.ps1','Core/Credentials.ps1','Core/Audit.ps1',
 'Server/Http.ps1','Server/Routes.ps1','Server/Jobs.ps1','Server/JobWork.ps1','Server/Session.ps1','Server/WebHost.ps1',
 'dev/fake-github.mjs','dev/fake-github.test.mjs','dev/Start-LocalDev.ps1','tests/e2e/host.e2e.mjs','tests/e2e/browser.e2e.mjs','tests/Intelligence.Tests.ps1','Core/Intelligence.ps1','dev/fake-ai.mjs','tests/Credentials.Tests.ps1',
 'docs/ROADMAP.md','TechStack',
 'Core/Lifecycle.ps1','Stop-Gangplank.ps1','web/heartbeat-worker.js',
 'assets/brand/emblem-dark.png','assets/brand/emblem-light.png','assets/brand/mark.svg','assets/brand/mark-256.png','assets/brand/favicon.ico','assets/brand/tray.ico'
)
$missing=@($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
if($missing.Count -gt 0){throw ('Gangplank critical files missing: '+($missing -join ', '))}
# Every test that loads Gangplank must isolate the credential store (TestIsolation.ps1):
# the CI runner is a real user account with real saved tokens.
$leaky = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.Tests.ps1' | Where-Object {
    $t = [IO.File]::ReadAllText($_.FullName)
    ($t -match "Import-Module \(Join-Path \`$root 'Gangplank\.psm1'\)") -and ($t -notmatch 'TestIsolation\.ps1')
} | ForEach-Object Name)
if($leaky.Count -gt 0){throw ('Tests load Gangplank without TestIsolation.ps1 (real credential store at risk): '+($leaky -join ', '))}
Write-Host ('Repository integrity passed: '+$required.Count+' required files present.') -ForegroundColor Green
