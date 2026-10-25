# Keystone Enterprise Workspace

Browser-first, no-Git-training development workspace built for Windows PowerShell 5.1 and a browser. No git.exe, Node or Python installation required.

**Engineering preview, not accredited enterprise production software.** See docs/SECURITY-MODEL.md.

## Launch
Double-click Launch-Keystone.bat for the browser UI. For the classic text menu run Launch-Keystone.bat -Cli. Or run Start-KeystoneWeb.ps1 from an approved PowerShell session.
The server binds to http://localhost:8769/. If HttpListener requires a URL reservation, work with your IT administrator.

**Stopping.** The browser tab owns the server. Keystone stops itself about 20 seconds after its last tab closes (5 seconds when the browser reports the tab closing); a reload or a second open tab keeps it running. It never stops in the middle of a request such as a save or a download. Other ways to stop it:
- **End session** at the bottom of the left navigation.
- Ctrl+C in its PowerShell window.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Stop-Keystone.ps1` stops every running Keystone host, including one in a hidden window, without needing its process ID. Each host gets up to 30 seconds to finish its current request before it is killed.

**One instance.** If Keystone is already running from this folder, the launcher shows it and asks *Stop it and start fresh?* (Enter = yes). `Launch-Keystone.bat --replace` answers yes without asking. `Launch-Keystone.bat --stay` keeps the server running after the tab closes. To turn auto-stop off permanently, set `KEYSTONE_AUTO_STOP=0` in the environment or `"AutoStop": false` in `config/keystone-config.json` (`KEYSTONE_AUTO_STOP=1` overrides the config file). Options pass through both launchers, for example `Launch-Keystone.bat -NoBrowser 19000 --stay`.

**Runtime files.** While it runs, the host writes `Logs\keystone-server-<pid>.json` (pid, port, url, start time; never the session token) and deletes it when it stops. The launcher and `Stop-Keystone.ps1` read these files and delete stale ones whose process has gone.

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

## ARC integration (GitHub, GitLab and GenAI)

**Keystone now loads ARC once in its own PowerShell process and performs the normal CAC + TOTP unlock before launching the browser.** It does not share unlock state with a separately opened ARC application. Follow the authentication prompts in the Keystone PowerShell window at startup; if ARC is cancelled, the browser still opens but can only use approved environment credentials.

1. Store the GitHub PAT as an ARC item named `github` or the GitLab PAT as `gitmil` (GenAI: `genapi`). These are defaults, not requirements.
2. Keep the ARC repository next to Keystone under `Projects\\arc`, or set `ARC_PATH` to the folder containing `pm.ps1` before launching Keystone. No separate Arc browser port is involved.
3. Start Keystone with `Launch-Keystone.bat` and complete the normal ARC unlock in that PowerShell console.
4. Open **Integrations** in Keystone's browser GUI. It reports ARC discovery, authentication, and each provider's mapped item status without revealing tokens.
5. If the ARC item name differs, select it in Integrations and click **Use this Arc item**. Only the service name is saved in `config/arc-items.local.json` (gitignored).
6. Then go back to **Overview**, enter your repository URL and click **Connect project**.

**If Integrations says "ARC found but not loaded":** Keystone located `pm.ps1`, but ARC's libraries or exported vault functions could not initialize. This is **not** a GitHub token or browser-port error. Update Keystone and open **Integrations → Copy safe diagnostics**. Its diagnostic code distinguishes `ARC_MISSING_MODULES` (specific absent files), `ARC_LIBRARY_INITIALIZATION_FAILED` (ARC itself failed to initialize), `ARC_HELPERS_UNAVAILABLE` (functions missing), and `ARC_IMPORT_EXCEPTION`. The copy contains no secrets, only booleans, mapped service names and safe module filenames. For missing files, update the **complete ARC repository**, including `lib/`; do not copy only `pm.ps1`. For initialization failures, run ARC's own approved launcher and inspect its local error logs; Keystone does not modify or bypass the vault.

Older ARC installations may expose `Ensure-VaultUnlocked`, `Find-VaultRows` / `Get-LiveVault`, and `Unprotect-SecretText` without `Get-PmStarkApiKey`. Keystone supports the core ARC API as a fallback. The web server never unlocks ARC from a request handler.

If Connect fails, Keystone distinguishes a missing ARC installation, locked vault, missing mapped item, and upstream 401/403/404 errors. A 401 indicates rejected credentials; 403 commonly means permissions or SSO/token-scope restrictions; 404 may mean a bad URL or unavailable repository access. Keystone does not return Git API response bodies or secrets to the browser.

For an environment-token-only session, the same startup path works without unlocking ARC. Enterprise application-control policies and CAC authentication remain unchanged.

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
Start-KeystoneWeb.ps1 hosts the browser API; Core/Lifecycle.ps1 holds the tab-presence rule, runtime files and instance discovery used by the host and Stop-Keystone.ps1; web/index.html is the UI (web/heartbeat-worker.js sends its heartbeat); Core/Workspace.ps1 provides the safe save workflow; Core/SmartSave.ps1 generates titles; Core/AI.ps1 handles approved AI streaming; Providers/ contains native GitHub and GitLab REST adapters; ArcBridge.ps1 integrates ARC; Keystone.ps1 is the CLI.


## Recovery / repository insight interface
The recovery branch restores the existing application and adds live, read-only provider-backed branches, recent commits, comparisons, open reviews, and simple recommendations. These features operate through existing PowerShell 5.1 GitHub/GitLab REST adapters. The UI uses plain-language labels and hover descriptions; read-only comparison is **not** merge or conflict resolution. The AI panel is still advisory and does not execute commands. Full Git workflows and a new frontend technology stack require separate implementation and workstation verification.
