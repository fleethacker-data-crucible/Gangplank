# Keystone roadmap

Browser-first Git workspace for people who don't use Git. Built to the shared
[`TechStack`](../TechStack) used by ARC, Cascade and Synapse. Last updated 2026-10-24.
Supersedes `docs/ENTERPRISE-ROADMAP.md`.

**Where work happens.** Most development is done off-workstation (cloud sessions and
the build PC) against synthetic data, mocks and ARC's software profile. Anything that
needs a CAC, the real web.git.mil instance or workstation application control is marked
**Workstation** and is done on the workstation (local model), never in the cloud.

## Done

| Area | Capability |
|---|---|
| Safety | Pinned download baseline, remote-HEAD check before save, non-forced GitHub ref updates, GitLab per-file commit guards, deletions unselected, Sentinel pre-publication scan |
| Review fixes (2026-10-24) | No environment switch can put the production host in LocalDev; CSP nonce independent of the CSRF token; provider response bodies stay in the local log; executable bits preserved on GitHub saves; 401/network errors no longer reported as "remote changed"; branch names encoded in ref paths |
| ARC 5 | Bridge uses ARC 5's `lib\Arc.ps1` contract (`Unlock-ArcVaultInteractive`, `Get-ArcSecret`, `Get-ArcItemNames`); ARC 3/4 `pm.ps1` kept as fallback; ARC 5 `pm.ps1` stub ignored. Tested against the real ARC 5 engine (software profile, temp data folder) |
| Host routes | Branches, history, compare, reviews, insights and Sentinel routes work (their functions were never exported); a test now fails if the host calls an unexported function |

## Next — host and plumbing (off-workstation)

| # | Item | Notes |
|---|---|---|
| 1 | TcpListener host on `127.0.0.1` | Per TechStack; removes the HttpListener URL-reservation failure mode. Follow ARC `lib/server/Http.ps1`: one-time launch nonce in the URL fragment → `HttpOnly; SameSite=Strict` cookie + `X-Keystone-Client` header, loopback Host/Origin checks, same-user peer check, header/body limits and timeouts, port fallback |
| 2 | Session state survives a restart | Today project, work branch and download baseline live only in memory: closing the window strands unsaved work. Persist non-secret state (project, branch, baseline SHA, file hash map) under `work\` |
| 3 | Background jobs | Download, save and AI stream block every other request today. Job model like Cascade's `JobManager` (start → poll `/api/jobs/{id}` → cancel), PS 5.1 runspaces, one exclusive job per kind |
| 4 | Provider hardening | Stable error codes (`AUTH_REJECTED`, `FORBIDDEN`, `NOT_FOUND`, `RATE_LIMITED`, `NETWORK`, as Cascade), bounded retry with `Retry-After` on reads only, `Link`/`X-Next-Page` pagination everywhere, no redirect following with a token attached, GitLab parity with the GitHub error handling |
| 5 | Synthetic provider for LocalDev and e2e | Node fake of the GitHub/GitLab endpoints Keystone uses (pattern: Cascade `tests/fakes/fake-github.mjs`). LocalDev becomes fully usable with fictional repos; "Test mode" banner as in ARC |
| 6 | Write audit log | Every remote write (branch, commit, review) appended to a local JSONL audit with time, project, branch, files and commit, never contents (Cascade `WriteGateway` pattern) |
| 7 | CI hygiene job | Copy ARC's: parse every `.ps1` under 5.1, block non-ASCII `.ps1` without BOM, logs, transcripts and vault files; pin actions by SHA; add `concurrency` |

## Next — UI rebuild (off-workstation)

| # | Item | Notes |
|---|---|---|
| 8 | New UI per TechStack | `ui-src/` → `ui/dist/`, TypeScript, Tailwind 4, CVA, Lucide, all bundled, strict CSP, no CDN. Framework choice below |
| 9 | Screens | Projects (recent, connect), Workspace (file tree with change status), Diff viewer, Smart Save review with Sentinel findings inline, Reviews (PR/MR list and status), History and branches, Integrations, Assistant dock |
| 10 | Diff in a Web Worker | Line diff for text files off the main thread; Rust → WASM later if large files need it |
| 11 | Browser tests | Unit tests plus Playwright e2e against the synthetic provider, on the Windows runner with the Edge channel (ARC pattern) |

**Decision needed:** Svelte 5 (ARC) or React 19 (Cascade, Synapse); and whether
`ui/dist` is committed with a staleness check (Synapse) or built in CI and shipped as a
release zip (ARC). Keystone has no workstation build step, so either a committed `dist`
or a release zip is required.

## Later — product capability

| # | Item | Notes |
|---|---|---|
| 12 | Get latest without starting over | Bring remote changes into an open workspace: apply non-overlapping files automatically, show overlaps for a choice. Today the only option is a fresh download |
| 13 | Reviews end to end | Status, checks and comments on PRs/MRs; reply; merge when branch policy allows |
| 14 | Sentinel review flow | "Review" findings (possible SSN, CUI marking) can be acknowledged per file with an audited reason; images and other binaries allowed by verified type instead of blocked outright; one shared rule list |
| 15 | Revert a file | Restore one file to the download baseline from the Workspace screen |
| 16 | AI with explicit consent | Read-only actions (explain this diff, summarize this review) that show exactly what will be sent before sending; still no tool execution |
| 17 | Retire the legacy CLI bulk upload | `Invoke-KeystonePush` and the classic menu once the browser flow covers them |

## Workstation (CAC, real endpoints, application control)

| # | Item | Notes |
|---|---|---|
| W1 | CAC unlock through Keystone's console | Launch-Keystone.bat → ARC 5 `Unlock-ArcVaultInteractive` with the card. Depends on ARC's own CAC testing (planned at the end of ARC's polish phase). Keystone adds no CAC code of its own |
| W2 | web.git.mil end to end | Connect, start a workspace, Smart Save, create a merge request against a sandbox project; confirm GitLab paging and per-file commit guards |
| W3 | Host under application control | Confirm the launcher and (after item 1) the TcpListener host run on the managed workstation with Edge |
| W4 | Runner account | The self-hosted runner should run as a dedicated account with no ARC vault; it currently finds ARC in the user profile |
| W5 | Signed release | Code-sign scripts if application control requires it |

## Shared with sibling products

- Cascade's ARC bridge (`module/Cascade/Arc.ps1`) still loads `pm.ps1` and is broken
  against ARC 5 the same way Keystone was. Keystone's `ArcBridge.ps1` is the model fix.
- The local server, ARC bridge, mock-provider and CI-hygiene pieces are near-identical
  across products; keep them as copied modules with a version header rather than
  diverging rewrites.

## Not doing

- Running Git commands or installing git.exe, Node or Python on the workstation.
- Letting the assistant change files, run tools or publish.
- Any unlock path other than ARC's own; any environment switch that weakens it.
