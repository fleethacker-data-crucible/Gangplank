# Keystone Enterprise — Implementation roadmap

> Superseded by [ROADMAP.md](ROADMAP.md) (2026-10-24). Kept for history.

## Current baseline (October 2026)
PowerShell 5.1, GitHub/GitLab API providers, archive download, folder upload, GitLab merge requests, ARC token bridge, CLI menu. No production browser host or integrated AI service exists in this repository yet.

## Product principles
- Browser-first, no Git vocabulary required for routine work.
- Save, share, and publish are separate actions.
- Offline deterministic commit-title fallback; optional approved AI provider.
- Diff previews, explicit file selection, secret detection, and safe concurrency checks before writes.
- No remote code execution from chat without an authorized, auditable approval workflow.
- PS 5.1 and constrained Windows environments remain first-class targets.

## Milestones
1. Safety: eliminate forced ref updates; detect stale remote HEAD; path allowlists and secret scanning; provider parity.
2. Smart Save: compare remote and local snapshots; stage selected files; generate commit messages; offer AI refinement; write only after approval.
3. Browser host: localhost-only HttpListener, random per-session CSRF token, origin checks, CSP, JSON API, shutdown lifecycle, friendly SPA.
4. AI assistant: streamed chat with provider adapter, conversation persistence, read-only project tools first, then reviewable change proposals.
5. Enterprise: identity/role enforcement, audit trail, team workflows, diagnostics, threat modeling, signed releases and deployment documentation.

## Acceptance gates
- No force-push in normal save flow.
- No deletion unless explicitly selected.
- Sensitive file patterns and oversized files rejected by default.
- Unauthorized cross-origin requests rejected.
- Tests pass under Windows PowerShell 5.1.
- Security and compliance review required before enterprise production deployment.
