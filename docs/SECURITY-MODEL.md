# Keystone enterprise foundation — security model

Development-stage tool, NOT an accredited enterprise deployment.

## Browser
- The PowerShell host listens on localhost and accepts only loopback requests.
- Every POST needs a per-process cryptographically random CSRF token in the `X-Keystone-Session` header. One exception: `POST /api/heartbeat` also accepts it as `session` in the JSON body, because the tab's unload beacon (`navigator.sendBeacon`) cannot set headers. The token never goes in a query string, the runtime file or the log, and request bodies are not logged. The Origin and Host checks apply to that route like any other, so another site cannot send the leaving signal.
- `POST /api/session/stop` (End session) additionally requires `X-Keystone-Intent: end-session`.
- Cross-origin requests are rejected; CSP, nosniff and frame restrictions are set.
- Repository and AI tokens remain inside PowerShell and never reach JavaScript.
- No arbitrary filesystem reader, script execution, or assistant tool execution endpoints.

## Network
- HTTPS GitHub and approved GitLab hosts only.
- AI gateway must use HTTPS and be on the administrator-controlled host allowlist.
- AI chat sends submitted text + project metadata; commit-message refinement sends filenames/statuses only.
- No repository source text goes to an AI endpoint automatically.
- Administrators must approve model usage for the data classification.

## Save safeguards
- Never delete or overwrite a nonempty download target.
- Pin each downloaded workspace to a remote commit.
- Check remote HEAD before upload; use GitHub force=false and GitLab per-file commit guards.
- Only selected changed files are uploaded. Deletions start unselected.
- Exclude common secrets filenames, linked files, and files >5 MB (not comprehensive DLP).

## Remaining production gates
- HttpListener URL permissions differ by Windows environment.
- No SSO, central RBAC, multi-user isolation, signed release, or formal security accreditation.
- Network races, GitHub/GitLab branch policies, and AI streaming require live integration tests.
- Legacy CLI full-folder upload still needs migration to strict workspace semantics.
- Code-signing, threat model, data handling policy, and enterprise security review remain required.
