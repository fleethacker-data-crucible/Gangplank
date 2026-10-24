# Keystone security model

Development-stage tool, NOT an accredited enterprise deployment.

## Local server
- `TcpListener` bound to 127.0.0.1 only; no HTTP.sys URL reservation.
- **Session:** the browser gets in through a one-time launch link (random nonce in the URL fragment, valid 120 s, burned on use) that is exchanged for an `HttpOnly; SameSite=Strict` cookie. A new link can be printed from the Keystone console (press L); each exchange replaces the previous session.
- **Every API call** needs that cookie, an `X-Keystone-Client` header (forces a CORS preflight from any other origin), a loopback `Host` (blocks DNS rebinding) and, if sent, a loopback `Origin`.
- **Same-user check (Windows):** connections from processes owned by another Windows account are refused.
- **Limits:** idle connections close after 2 s, headers within 5 s and 32 KB, bodies 1 MB; `Transfer-Encoding` and duplicate `Content-Length` are rejected.
- **Static files:** only the UI files in the manifest are served.
- **Headers:** CSP `default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'` (no inline script or style), `X-Frame-Options: DENY`, `nosniff`, `no-store`, `no-referrer`, same-origin CORP/COOP.
- **Errors** reach the browser as a code and one safe line; provider response bodies and stack traces stay in the local log.

## Credentials
- Order: environment variable, then Keystone's store, then ARC if explicitly configured.
- **Keystone's store:** tokens entered in the UI are write-only. They are sealed with Windows DPAPI (current user, with Keystone-specific entropy) in `%LOCALAPPDATA%\Keystone\credentials.json`. Another account, or a copied file, cannot unseal them. Without DPAPI the store refuses to save.
- **ARC** is opt-in (Credentials setting or `KEYSTONE_ARC_PATH`); nothing is auto-detected. Unlock is ARC's own console flow, run once at startup before the server listens, never from a browser request. Keystone adds no CAC or passphrase handling.
- **Tokens never go to** the browser, the log, the audit trail or job results. Background jobs receive the token in memory from the host's main thread.

## Network
- Repositories: HTTPS github.com, web.git.mil and administrator-approved `KEYSTONE_GITLAB_ALLOWED_HOSTS` only.
- All provider calls use one transport with **redirects off**. Archive downloads follow redirects themselves and send the token only to the original host (GitHub's codeload redirect gets no token).
- GET requests are retried on 429/5xx/network errors, honouring `Retry-After` (max 10 s). Writes are never retried.
- **AI:** HTTPS gateways on the administrator allowlist only. Chat sends the typed text plus project and branch name; commit-title help sends file names and statuses only. No source text is sent automatically. Administrators must approve model use for the data classification.

## Save safeguards
- A download never deletes or overwrites a non-empty folder, and each workspace is pinned to a remote commit.
- The remote head is checked before upload. GitHub updates use `force=false`; GitLab uses per-file `last_commit_id` guards.
- Only selected changed files are uploaded, with their existing Git modes. Deletions start unselected.
- Sentinel blocks likely secrets, CUI markings, personal identifiers, linked files, unscanned formats and files over 5 MB. It is pattern-based, not complete DLP.
- Every remote write and credential/setting change is appended to `Logs\audit.jsonl`, without contents or tokens.

## LocalDev
- Only the explicit `-LocalDev` switch enables it; no environment variable can.
- In LocalDev, ARC is never imported. The synthetic provider (`-DevGitHubUrl`) is refused outside LocalDev and limited to loopback http.

## Remaining production gates
- Real CAC unlock through ARC 5 and web.git.mil end to end on the workstation (roadmap W1-W3).
- The self-hosted runner should use a dedicated account without an ARC vault (W4).
- No SSO, central RBAC, multi-user isolation, signed release or formal accreditation.
- A threat model, data-handling policy and enterprise security review are still required.
