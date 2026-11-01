# Gangplank roadmap

Browser-first Git workspace for people who don't use Git. Built to the shared
[`TechStack`](../TechStack) used by Lazarette, Halyard and Shellback. Last updated 2026-10-31 (draft PRs listed below).
Supersedes `docs/ENTERPRISE-ROADMAP.md`.

**Where work happens.** Most development is done off-workstation (cloud sessions and
the build PC) against synthetic data, mocks and Lazarette's software profile. Anything that
needs a smart card, the organization's real GitLab host or workstation application control is marked
**Workstation** and is done on the workstation (local model), never in the cloud.

## Done

| Area | Capability |
|---|---|
| Safety | Pinned download baseline, remote-HEAD check before save, non-forced GitHub ref updates, GitLab per-file commit guards, deletions unselected, Sentinel pre-publication scan |
| Review fixes (2026-10-24) | No environment switch can put the production host in LocalDev; CSP nonce independent of the CSRF token; provider response bodies stay in the local log; executable bits preserved on GitHub saves; 401/network errors no longer reported as "remote changed"; branch names encoded in ref paths |
| Lazarette | Bridge uses Lazarette's `lib\Lazarette.ps1` contract (`Unlock-LazaretteVaultInteractive` / `Get-LazaretteSecret` / `Get-LazaretteItemNames` / `Test-LazaretteVaultUnlocked`) and nothing else: no other loader, function names or `pm.ps1`. Tested against the real Lazarette engine (software profile, temp data folder) |
| Host routes | Branches, history, compare, reviews, insights and Sentinel routes work (their functions were never exported); a test now fails if the host calls an unexported function |
| Credentials | Lazarette is opt-in (Credentials setting or `GANGPLANK_LAZARETTE_PATH`), never auto-detected. Tokens can be entered once in the UI and are sealed with Windows DPAPI; environment variables still work |
| Host (roadmap 1) | TcpListener on 127.0.0.1, one-time launch link to an `HttpOnly; SameSite=Strict` cookie, client header, loopback Host/Origin, same-user peer check, limits, manifest-only static files, CSP without inline code |
| Sessions (2) | Project, work branch and download baseline saved under `work\.keystone` (now `%LOCALAPPDATA%\Gangplank`) and restored on restart |
| Jobs (3) | Connect, start, download, save, review and AI run in background runspaces; one workspace job at a time; the UI polls progress |
| Providers (4) | One transport for GitHub, GitLab and AI: coded errors, GET-only retry with `Retry-After`, no token on cross-host redirects, UTF-8 bodies, GitHub empty-repo 409 handled |
| LocalDev and e2e (5) | Synthetic GitHub (`dev/fake-github.mjs`), `Launch-LocalDev.bat`, and an end-to-end test that drives the real host through connect, start, Smart Save, review, stale branch and restart |
| Audit (6) | `Logs\audit.jsonl` for every remote write and credential/Lazarette change, shown in the UI |
| Work branches | Users name their work branch (friendly names become valid branch names; duplicates and invalid names are refused clearly) |
| Workspace folder | Workspaces live in `%USERPROFILE%\Gangplank\<repo>\<branch>` (configurable), outside the program folder; Gangplank's own state in `%LOCALAPPDATA%\Gangplank` |
| AI model | One endpoint setting with discovery: OpenAI-compatible, Azure OpenAI, Databricks, Ollama; chat-model filter and ranking; Test; Halyard's `LLM_*` variables honoured |
| CI (7) | Hygiene job (5.1 parse, non-ASCII without BOM, tracked logs/credentials), pinned actions, concurrency, 5.1 suites, e2e under Windows PowerShell 5.1 |
| Pagination (4b) | Branch lists follow `Link` (RFC 8288) and `X-Next-Page` headers, with a count-based fallback for a full page that carries neither. Lists stop at 50 pages, and a paging link to another host is refused. Tested offline in `tests/Paging.Tests.ps1` |
| Job cancel (6b) | A Cancel bar shows while a background job runs and calls `POST /api/jobs/{id}/cancel`. A cancelled job reports that it stopped before finishing, and changes already sent are not undone. The offline checks cover the markup only; a browser check of the button is not yet in CI |

## Next — host follow-ups (off-workstation)

| # | Item | Notes |
|---|---|---|
| 5b | Synthetic GitLab | The synthetic server covers GitHub; GitLab paths are covered by unit tests only |

## Next — UI rebuild (off-workstation)

| # | Item | Notes |
|---|---|---|
| 8 | New UI per TechStack | `ui-src/` → `ui/dist/`, TypeScript, Tailwind 4, CVA, Lucide, all bundled, strict CSP, no CDN. Framework choice below |
| 9 | Screens | Projects (recent, connect), Workspace (file tree with change status), Diff viewer, Smart Save review with Sentinel findings inline, Reviews (PR/MR list and status), History and branches, Integrations, Assistant dock |
| 10 | Diff in a Web Worker | Line diff for text files off the main thread; Rust → WASM later if large files need it |
| 11 | Browser tests | Unit tests plus Playwright e2e against the synthetic provider, on the Windows runner with the Edge channel (Lazarette pattern) |

**Decision needed:** Svelte 5 (Lazarette) or React 19 (Halyard, Shellback); and whether
`ui/dist` is committed with a staleness check (Shellback) or built in CI and shipped as a
release zip (Lazarette). Gangplank has no workstation build step, so either a committed `dist`
or a release zip is required.

## Later — product capability

| # | Item | Notes |
|---|---|---|
| 12 | Get latest without starting over | Bring remote changes into an open workspace: apply non-overlapping files automatically, show overlaps for a choice. Today the only option is a fresh download |
| 13 | Reviews end to end | Status, checks and comments on PRs/MRs; reply; merge when branch policy allows |
| 14 | Sentinel review flow | "Review" findings (possible SSN, data-handling marking) can be acknowledged per file with an audited reason; images and other binaries allowed by verified type instead of blocked outright; one shared rule list |
| 15 | Revert a file | Restore one file to the download baseline from the Workspace screen |
| 16 | AI with explicit consent | Read-only actions (explain this diff, summarize this review) that show exactly what will be sent before sending; still no tool execution |
| 16b | Use an existing folder | Adopt a git clone (base commit from `.git\HEAD`, file hashes compared with the remote tree) or a plain folder matched to a branch commit |
| 16c | Shared AI module | Gangplank's endpoint discovery (`Core/Intelligence.ps1`) could become the common AI setting for Halyard and Shellback |
| 17 | Retire the legacy CLI bulk upload | `Invoke-GangplankPush` and the classic menu once the browser flow covers them |

## Workstation (smart card, real endpoints, application control)

| # | Item | Notes |
|---|---|---|
| W1 | Smart card unlock through Gangplank's console | When Lazarette is ready: turn Lazarette on in Credentials, restart, and unlock with the card (Lazarette `Unlock-LazaretteVaultInteractive`). Depends on Lazarette's own smart card testing (planned at the end of Lazarette's polish phase). Gangplank adds no smart card code of its own |
| W2 | Organization GitLab host end to end | Connect, start a workspace, Smart Save, create a merge request against a sandbox project; confirm GitLab paging and per-file commit guards |
| W3 | Host under application control | Confirm the launcher and (after item 1) the TcpListener host run on the managed workstation with Edge |
| W4 | Runner account | The self-hosted runner should run as a dedicated account with no Lazarette vault. Gangplank no longer auto-detects Lazarette, so tests can no longer pick it up, but the account still holds it |
| W5 | Signed release | Code-sign scripts if application control requires it |

## Built, waiting to merge (draft pull requests, 2026-10-31)

Each row has code and tests on its branch and is not on `main` yet, so it stays out of the Done table
until its pull request merges. Rows already in the tables above that these cover: 4b, 6b, 10, 12, 13, 14, 15, 16 (in part), 16b, 16c (the contract), 17, and a first slice of 8 and 9.

| # | Item | Where | Tested by |
|---|---|---|---|
| 4b, 6b | Paging through `Link` / `X-Next-Page`; a Cancel bar for running jobs | PR #41 | `tests/Paging.Tests.ps1`, `tests/BrowserSyntax.Tests.cjs` |
| 10 | Diff viewer with the line diff in a Web Worker | PR #40 | `tests/DiffWorker.test.mjs`, `tests/FileDiff.Tests.ps1` |
| 13 | Reviews end to end: detail, checks, comments, guarded merge | PR #42 | `tests/Reviews.Tests.ps1`, `dev/fake-github.test.mjs` |
| 12 | Get latest: apply online changes, ask on overlaps | branch `feature/get-latest` | `tests/GetLatest.Tests.ps1`, host e2e |
| 15 | Revert one file to the downloaded version | branch `feature/revert-file` | `tests/Revert.Tests.ps1`, host e2e |
| 16b | Use a git clone or a plain folder as the workspace | branch `feature/adopt-folder` | `tests/Adopt.Tests.ps1`, host e2e |
| 17 | Retire the legacy bulk upload (the classic text menu stays as the CLI) | branch `feature/retire-legacy-push` | `tests/LegacyRetired.Tests.ps1` |
| new | Publish a plain folder to a new work branch (stacked on 16b) | branch `feature/publish-folder` | `tests/Adopt.Tests.ps1`, host e2e |
| new | Spoken status with the browser's local voices (opt-in) | branch `feature/spoken-status` | `tests/BrowserSyntax.Tests.cjs` |
| new | AI defaults to the Fleet router; Lazarette bridge reference and vault-flow test | PR #43 | `tests/Intelligence.Tests.ps1`, `tests/LazaretteVaultFlow.Tests.ps1` |
| 14 | Sentinel review flow: reasoned, audited acknowledgements; verified images and PDFs; one rule list | branch `feature/sentinel-acknowledge` | `tests/Sentinel.Tests.ps1`, host e2e |
| 16 | AI with explicit consent: "Explain this file" shows exactly what is sent and sends only that. "Summarize this review" is not built | branch `feature/ai-explain-consent` | `tests/AiConsent.Tests.ps1`, host e2e |
| 16c | Shared AI module: version, documented host contract, contract test. The copies in Halyard and Shellback are not made | branch `feature/shared-ai-contract` | `tests/IntelligenceContract.Tests.ps1` |
| 8, 9 | First slice of the UI rebuild: a typed API client in `ui-src` (no Svelte project or screens yet) | branch `feature/ui-src-api-client` | `ui-src/tests/api.test.ts`, `ui-src/tests/host.contract.test.ts` |
| CI | The diff worker test runs in CI (merge after #40) | branch `ci/diff-worker-test` | the CI run itself |

Already true on `main`: 5b (synthetic GitLab, #39) and 11 (the Playwright browser test runs in CI on the
Windows runner with Edge: run 41224330942 ran it, 1 test, 0 skipped). Both rows above still read as open and
are updated when the pull requests above merge.

**Not finished:** 8 and 9 (the Svelte project, every screen and the dist staleness check), 16 (only the
first action), 16c (the copies in the sibling products). **Not started:** Fleet UI v0.2. **Needs the workstation or a live service:** W1 to W5,
a live Fairlead or TalkForge (spoken status through the router is not wired), and a smart card vault.

## Shared with sibling products

- Fleet integrations (issue 37): AI now defaults to the Fleet router, Fairlead, at 127.0.0.1:8776 (model auto, X-Fairlead-Privacy: local; tested with a scripted transport and the host e2e). The Lazarette bridge has a reference, docs/LAZARETTE-BRIDGE.md, and a vault-flow test. Not done: spoken status (TalkForge and speech in, through Fairlead), publishing Capstan and Scrimshaw output, reading the Fairlead client key from Lazarette, Fleet UI v0.2, and a CLI/API beyond the text menu.
- Halyard's Lazarette bridge (`module/Halyard/Lazarette.ps1`) still loads `pm.ps1` and is broken
  against Lazarette the same way Gangplank was. Gangplank's `LazaretteBridge.ps1` is the model fix.
- The local server, Lazarette bridge, mock-provider and CI-hygiene pieces are near-identical
  across products; keep them as copied modules with a version header rather than
  diverging rewrites.

## Not doing

- Running Git commands or installing git.exe, Node or Python on the workstation.
- Letting the assistant change files, run tools or publish.
- Any unlock path other than Lazarette's own; any environment switch that weakens it.
