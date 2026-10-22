# KEYSTONE — local development (no CAC)

Run `Launch-LocalDev.bat` from this repository on your **personal Windows PC** after checking out the feature branch. Do not use on a managed system to defeat organizational security policy.

## What it does

- Prerequisite: Windows PowerShell 5.1; no CAC needed.
- Startup: Passes -LocalDev so the host does not import Arc or request an unlock. The GUI remains available, including local diagnostics.
- Boundary: Remote GitHub/GitLab operations and AI still require authorized provider credentials. This is not a simulated Git provider.
- Diagnostics / manual check: `powershell.exe -NoProfile -File Start-KeystoneWeb.ps1 -LocalDev -NoBrowser`.

## Workflow

```powershell
git fetch origin
git switch feature/local-dev-no-cac-launcher
.\Launch-LocalDev.bat
```

The original production launcher and authentication checks remain unchanged. Mock, local, or offline sessions are **not** authenticated Navy sessions, and must not contain CUI, real credentials, classified material, or production personal data.

When stable, remove `Launch-LocalDev.bat` (and the ARC mock files where applicable) from the release branch. Do not deploy them as a means of avoiding CAC or authorization for live systems.
