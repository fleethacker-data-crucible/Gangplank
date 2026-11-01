# Gangplank security model

Development-stage tool, NOT an accredited enterprise deployment.

## Local server
- `TcpListener` bound to 127.0.0.1 only; no HTTP.sys URL reservation.
- **Session:** the browser gets in through a one-time launch link (random nonce in the URL fragment, valid 120 s, burned on use). The exchange sets an `HttpOnly; SameSite=Strict` cookie **and** returns a second random secret in the response body, which the page keeps in `sessionStorage` for that tab. A new link can be printed from the Gangplank console (press L); each exchange replaces the previous session.
- **Every API call** needs both: the cookie and the secret in `X-Gangplank-Client`. Browsers send localhost cookies to every port, so a cookie captured by another local server is useless without the tab's secret. The custom header also forces a CORS preflight from any other origin. A loopback `Host` (blocks DNS rebinding) and, if sent, a loopback `Origin` are required too.
- **Same-user check (Windows):** connections from processes owned by another Windows account, or whose owner cannot be read, are refused.
- **Limits:** idle connections close after 2 s, headers within 5 s and 32 KB, bodies 1 MB; `Transfer-Encoding` and duplicate `Content-Length` are rejected.
- **Static files:** only the UI files in the manifest are served.
- **Lifecycle:** `POST /api/heartbeat` (tab presence) needs the session cookie and the client secret like every other call. The tab's unload beacon (`navigator.sendBeacon`) cannot set headers, so on that one route the secret may instead be `client` in the JSON body; it never goes in a query string, the runtime file or the log, and request bodies are not logged. `POST /api/session/stop` (End session) additionally requires `X-Gangplank-Intent: end-session`. Stop requests from `Stop-Gangplank.ps1` use a per-process named event (`Local\Gangplank-Stop-<pid>`); the host stops between requests and after running background jobs finish.
- **Headers:** CSP `default-src 'none'; script-src 'self'; worker-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'` (no inline script or style), `X-Frame-Options: DENY`, `nosniff`, `no-store`, `no-referrer`, same-origin CORP/COOP.
- **Errors** reach the browser as a code and one safe line; provider response bodies and stack traces stay in the local log.

## Credentials
- Order: environment variable, then Gangplank's store, then Lazarette if explicitly configured.
- **Gangplank's store:** tokens entered in the UI are write-only. They are sealed with Windows DPAPI (current user, with Gangplank-specific entropy) in `%LOCALAPPDATA%\Gangplank\credentials.json`. Another account, or a copied file, cannot unseal them. Without DPAPI the store refuses to save.
- **Lazarette** is opt-in (Credentials setting or `GANGPLANK_LAZARETTE_PATH`); nothing is auto-detected, and network-share paths are refused. Unlock is Lazarette's own console flow, run once at startup before the server listens, never from a browser request. Gangplank adds no smart card or passphrase handling.
- **Tokens never go to** the browser, the log, the audit trail or job results. Background jobs receive the token in memory from the host's main thread.

## Network
- Repositories: HTTPS github.com, your organization's GitLab host (`GANGPLANK_GITLAB_HOST` or `GitLabHost` in the config) and administrator-approved `GANGPLANK_GITLAB_ALLOWED_HOSTS` only.
- All provider calls use one transport with **redirects off**. Archive downloads follow redirects themselves and send the token only to the original host (GitHub's codeload redirect gets no token).
- API reads follow redirects on the same host only (renamed repositories); other hosts never get the token.
- Background GET requests are retried on 429/5xx/network errors, honouring `Retry-After` (max 10 s); reads answered directly on the HTTP loop make one attempt with a 20 s timeout. Writes are never retried.
- **AI:** Gangplank sends AI requests only to Fairlead on this PC. The address must be a loopback address without embedded credentials (anything else is refused before a request leaves). The Fairlead client key is read from Windows Credential Manager (`Fairlead/Gangplank`) just before a request, held only in memory, sent as a bearer token and never logged, stored by Gangplank or returned to the browser. Requests ask Fairlead to keep them on this PC (`X-Fairlead-Privacy: local`).

## Save safeguards
- A download never deletes or overwrites a non-empty folder, and each workspace is pinned to a remote commit.
- The remote head is checked before upload. GitHub updates use `force=false`; GitLab uses per-file `last_commit_id` guards.
- Only selected changed files are uploaded, with their existing Git modes. Deletions start unselected.
- Sentinel blocks likely secrets, data-handling markings, personal identifiers, linked files, unscanned formats and files over 5 MB. It is pattern-based, not complete DLP.
- Every remote write and credential/setting change is appended to `Logs\audit.jsonl`, without contents or tokens.
- A restored session is re-checked against the repository host allowlist, so a session saved in LocalDev can never send a real token to a local address.

## LocalDev
- Only the explicit `-LocalDev` switch enables it; no environment variable can.
- In LocalDev, Lazarette is never imported. The synthetic provider (`-DevGitHubUrl`) is refused outside LocalDev and limited to loopback http.

## Remaining production gates
- Real smart card unlock through Lazarette and your organization's GitLab host end to end on the workstation (roadmap W1-W3).
- The self-hosted runner should use a dedicated account without a Lazarette vault (W4).
- No SSO, central RBAC, multi-user isolation, signed release or formal accreditation.
- A threat model, data-handling policy and enterprise security review are still required.
