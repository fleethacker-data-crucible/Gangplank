# Keystone (Phase A/B)

Modular PowerShell tool - GitLab + GitHub **without git.exe**.

## Menus
1. Open project (URL)
2. Get latest files (branch zip snapshot)
3. Share my folder (push commit; works on empty repos)
4. Create merge request (GitLab)
5. List branches
6. Session / Explorer

## ARC Service names
- GitLab: `gitmil`
- GitHub: `github`

## Token scopes
- GitLab PAT: `api` (or write_repository + read_api as required by your host)
- GitHub: Contents read/write for push; classic `repo` for private

## Layout
See Core/, Providers/, ArcBridge.ps1

## Smoke test
1. Open empty GitHub repo URL
2. Share my folder -> this Keystone folder -> main
3. Refresh GitHub - files should appear
