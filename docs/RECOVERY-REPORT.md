# Keystone recovery and rebuild report

## Incident and baseline
- Broken `main` merge: `60adf3c73184a78de003dd4926bc015f785c460e` (PR #11).
- Last intact baseline: `be1bd871c7969f044f9d480ecfbf3ecb7d7c7ed3`.
- The bad merged tree contained **4 files**, versus **30 tracked files** in the intact baseline.
- Root cause: feature commits were created from incomplete Git tree objects. Merging the branch deleted 26 baseline files. No direct force push was involved in this recovery.
- Recovery created on a new branch from broken `main`, with the complete original Git tree used as the base for all modifications. No changes were made to `main` during this repair.

## What this branch restores
All original launchers, PowerShell modules, GitHub/GitLab providers, ARC integration, workspaces, configuration, docs, tests, and GitHub workflow definitions.

## Improvements retained / added
- Sentinel local selected-file scan before Smart Save writes remote commits; warnings for credentials, candidate PII/CUI, unscannable files and public repository visibility.
- GitHub and GitLab visibility verification, with explicit public repository confirmation and policy gate.
- Read-only GitHub/GitLab branch lists, 30 recent commits, branch-to-branch change summaries, open pull/merge requests, and basic repository recommendations.
- Plain-language browser descriptions and tooltips, without separate beginner/developer modes.
- Repository-integrity and JavaScript syntax tests; Windows PowerShell CI now exercises Sentinel and insights mocks.

## Known limitations
- **No full Git engine:** remote snapshot download and Smart Save are not equivalent to a complete local `git clone`/fetch/rebase/merge/stash implementation.
- AI remains advisory and cannot execute Git operations.
- Sentinel is not accredited DLP; it does not inspect full outgoing commit history, binary attachments, OCR, or all metadata. Unsupported binary files are blocked from Smart Save.
- Even a clean scan or a private repository does not establish public-release/CUI authorization.
- Modern Svelte/TypeScript, WASM, .NET, and SQLite migration was not undertaken during this emergency restoration.
- GitHub Actions CI validates Windows PowerShell fixtures and browser script syntax. Actual Nautilus/CAC integration still requires workstation acceptance testing.

## Before merging
1. Confirm the PR has **no deleted files** and retains the original repository folders.
2. Confirm `Keystone PowerShell checks` is green.
3. Review diffs for `Core/Workspace.ps1`, `Core/Sentinel.ps1`, `Core/RepositoryInsights.ps1`, `Start-KeystoneWeb.ps1`, `web/index.html`.
4. Run locally on your personal test workstation: `Launch-LocalDev.bat` for no-ARC development, or `Launch-Keystone.bat` with approved credentials.
5. Connect an authorized **test** repository, inspect Branches/Compare/History/Reviews, create a work branch, and publish only synthetic test content.
6. Expect public publishing to be disabled unless the administrator has deliberately configured `KEYSTONE_ALLOW_PUBLIC_PUBLISH=1`; still require authorization and explicit user confirmation.

## Future prevention
Protect `main` with mandatory status checks, PR review, and restrictions on force pushes/deletions. The repository integrity test prevents regressions when CI is running, but repository protections must enforce required checks even if a branch removes its own workflow definition.
