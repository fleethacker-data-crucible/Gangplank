# Sentinel security foundation (engineering preview)

This branch adds a preliminary local-only classifier in Core/Sentinel.ps1 and a standalone test script. **Not yet wired into Smart Save, so it does not currently protect publication.** Do not claim otherwise.

## Immediate integration work
- Wire the classifier into the preview and final publish paths, with safe per-file findings in the browser.
- Verify GitHub visibility at publish time, require explicit public confirmation, and block on unavailable visibility.
- Define approved GitLab destination policy; do not assume web.git.mil is IL5 or approved for every category.
- Add scoped, auditable false-positive and synthetic-fixture approvals; changes invalidate approvals.
- Scan entire outgoing Git history where applicable, metadata, archives, PDFs and images, with explicit unverified results.
- Add tests using Windows PowerShell 5.1 and mocked GitHub/GitLab REST calls; run on the target Nautilus workstation.

## Technology direction
Preserve current PowerShell 5.1 launch and ARC integration while validating Svelte/TypeScript UI, optional Rust WASM for browser compute, SQLite durability, and an approved .NET host. Do not assume .NET/SQLite availability on Nautilus before target-device tests. Migrate behind existing interfaces in small tested slices.

## Safety
No automated determination of public-release authorization. Do not send potentially sensitive content to AI without verified endpoint policy. A private repository is not a CUI authorization.
