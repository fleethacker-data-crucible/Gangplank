# Keystone Enterprise Workspace

Browser-first, no-Git-training development workspace built for Windows PowerShell 5.1 and a browser. No git.exe, Node or Python installation required.

**Engineering preview, not accredited enterprise production software.** See docs/SECURITY-MODEL.md.

## Launch
Double-click Launch-Keystone.bat for the browser UI. For the classic text menu run Launch-Keystone.bat -Cli. Or run Start-KeystoneWeb.ps1 from an approved PowerShell session.
The server binds to http://localhost:8769/. Press Ctrl+C in its PowerShell window to stop. If HttpListener requires a URL reservation, work with your IT administrator.

**Restricted PowerShell launch compatibility:** The batch file uses the same process-scoped `-STA -NoProfile -ExecutionPolicy Bypass` startup switches as ARC and Cascade. This applies only to the launched process and does not modify your device's execution-policy settings or override enforced Group Policy, application control, or IT authorization requirements.

For troubleshooting, run `Launch-Keystone.bat -NoBrowser` to start the host without opening a browser. To choose a port, run `Launch-Keystone.bat -NoBrowser 8770`, then open `http://localhost:8770/`. A PowerShell script-policy error is different from an HttpListener access-denied/URL-reservation error; the latter requires an IT-approved configuration rather than changing PowerShell launch flags.

## Connect → Download → Edit → Smart Save
1. Paste a GitHub or GitLab project URL and connect using your configured credentials.
2. Click **Start my safe workspace**. Keystone creates an isolated work branch and downloads a fresh snapshot into a new folder. Existing local work is never overwritten.
3. Edit files using your normal tools.
4. Open Smart Save, refresh and choose exactly which added or modified files to publish. Deletions are unselected by default.
5. Accept the automatically generated commit title, or explicitly request a filename-only AI suggestion, then confirm publication.
6. Click **Create review request** to have Keystone automatically compose a GitHub pull request or GitLab merge request for your changes.

Keystone checks the remote HEAD against your pinned download baseline, uses non-forced GitHub branch updates, and GitLab per-file commit guards. If others updated the branch, publishing stops. Direct saves to the default branch are disabled unless KEYSTONE_ALLOW_DEFAULT_BRANCH_WRITES=1 is explicitly set.
Smart Save publishes directly to the remote branch. It is not an offline-only backup or staging mechanism.

## AI assistant
Assistant chat is a read-only, token-streaming advisor backed by an administrator-approved OpenAI-compatible HTTPS chat endpoint.
Default endpoint: https://api.genai.mil/v1/chat/completions . Default model: gemini-3.8-flash (override with KEYSTONE_AI_MODEL after confirming approved availability).
Set GENAI_TOKEN or KEYSTONE_AI_TOKEN in the PowerShell launch environment, or authenticate ARC and unlock the genapi item. Additional approved AI hosts may be configured with KEYSTONE_AI_ALLOWED_HOSTS.
Your explicit chat text and project/branch name go to the selected AI provider. AI commit-title refinement sends filenames and statuses only. Source code is never sent to AI automatically.

## Credentials and trust
GitHub credential: GITHUB_TOKEN or ARC github. GitLab: GITLAB_TOKEN or ARC gitmil.
Only HTTPS github.com, web.git.mil and administrator-approved KEYSTONE_GITLAB_ALLOWED_HOSTS are permitted for repository connections.
Do not commit API tokens in scripts or configuration. Obtain approval for the data classification before using any model gateway.

## Tests
Windows PowerShell 5.1: run tests/SmartSave.Tests.ps1 and tests/Workspace.Tests.ps1. GitHub Actions runs them on Windows.

## Important limits
- The verified browser flow requires an existing initialized remote branch. Empty repo bootstrap is a future feature.
- The assistant cannot autonomously change code, run tools, or create patches.
- Common credential filenames/obvious secret patterns and files >5 MB are blocked; this is not comprehensive DLP.
- Enterprise SSO, RBAC, signing, formal audits, CI integration and security authorization remain future milestones.
- Deprecated legacy bulk upload API remains available to existing module consumers; new workflows should use Smart Save.

## Source layout
Start-KeystoneWeb.ps1 hosts the browser API; web/index.html is the UI; Core/Workspace.ps1 provides the safe save workflow; Core/SmartSave.ps1 generates titles; Core/AI.ps1 handles approved AI streaming; Providers/ contains native GitHub and GitLab REST adapters; ArcBridge.ps1 integrates ARC; Keystone.ps1 is the CLI.
