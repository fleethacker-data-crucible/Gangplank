# Keystone Sentinel — recovered safety baseline

Sentinel runs before Smart Save creates remote Git objects. It re-reads repository visibility using provider APIs and scans the selected changed files locally. The browser Security tab exposes findings without returning matched secrets.

## Provider policy
- GitHub and GitLab: visibility is checked immediately before publication. Unknown visibility blocks the request.
- Public repositories: Smart Save is disabled by default; administrators must enable `KEYSTONE_ALLOW_PUBLIC_PUBLISH=1` **and** users must confirm publishing. This flag does **not** authorize releasing government information.
- Private/internal repositories: passing a scan does **not** establish CUI/PII authorization or an IL5 boundary. Confirm destination accreditation and data handling requirements independently.
- Flagged credentials and potential CUI or personal identifiers block publication for manual review. There is no one-click risk bypass.
- Files Keystone cannot inspect, including PDF/images/archives, are blocked from Smart Save until dedicated scanners are implemented; the original file is not modified.

## Limitations
This is a pattern-based, selected-file guard, **not** complete DLP: no Git history, commit metadata, OCR, archives, behavioral anomaly detection, centralized enforcement, exception management, or standalone `git push` interception. Alternate tools and GitHub/GitLab web interfaces can bypass this local guard. AI does not automatically read content or execute tools. Tests use mock provider responses and run with PowerShell 5.1 in CI.
