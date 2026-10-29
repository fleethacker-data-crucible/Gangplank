# Gangplank LocalDev

LocalDev runs the **real** Gangplank host in test mode against a synthetic GitHub
(`dev/fake-github.mjs`), so you can develop and try the whole flow with fictional
repositories. Use it on a development PC only. It is not a way around Lazarette,
smart card or any authorization on a managed system.

## Start

Double-click **Launch-LocalDev.bat** (needs Node.js 18+ on the development PC).

- Starts the synthetic GitHub on `http://127.0.0.1:8791` with the fictional repo
  `gangplank-demo/sample` (also `gangplank-demo/public-site` and an empty repo).
- Starts Gangplank with `-LocalDev -DevGitHubUrl ...`: no Lazarette import, no unlock
  prompts, a **Test mode** banner, and a fake `GITHUB_TOKEN` for that process only.
- Workspaces go to `work-localdev\` (ignored by Git). The repo URL field is prefilled.

Without Node, the host still starts in LocalDev with no provider.

Lifecycle is the same as the production launcher: the host stops itself when its browser tab closes; `Launch-LocalDev.bat --stay` keeps it running, `--replace` restarts without asking, and `Stop-Gangplank.ps1` stops any leftover host. LocalDev keeps its session under `work-localdev\`, so it never counts as "already running" against your real Gangplank.

Manual: `powershell -File dev\Start-LocalDev.ps1 [-Port 8769] [-FakePort 8791] [-NoBrowser]`,
or `node dev/fake-github.mjs 8791` and `Start-Gangplank.ps1 -LocalDev -DevGitHubUrl http://127.0.0.1:8791/`.

## Synthetic GitHub controls (test only)

`POST /__fake/reset`, `GET /__fake/state` (call log, including whether a token
reached the archive redirect), `POST /__fake/fail {method, pathContains, status,
times, retryAfter}` to inject 429/5xx, and `POST /__fake/advance {branch}` to
simulate a teammate pushing.

## Boundaries

- LocalDev is only ever the explicit `-LocalDev` switch; no environment variable turns it on.
- `-DevGitHubUrl` is refused without `-LocalDev` and accepts only `http://127.0.0.1` / `localhost`.
- Fictional data only: never real credentials, sensitive or regulated data or personal data.
- Production is started with `Launch-Gangplank.bat`; do not ship `dev\` or `Launch-LocalDev.bat` in a release.
