# Shared AI module

`Core/Intelligence.ps1` gives a product one AI setting for any gateway: the user gives an
endpoint, and the module works out what it is (OpenAI-compatible, Azure OpenAI, Databricks, Ollama)
and which chat models it offers. Halyard and Shellback can use the same file, so one setup serves
all three apps (roadmap 16c).

This is **version 1.0.0** of the module. It is copied into each product, not forked: change it here,
bump the version, and copy it back. The version is the line `# Shared module. Gangplank Intelligence,
version X.Y.Z` at the top of the file; `tests/IntelligenceContract.Tests.ps1` checks that it matches
this guide.

## What a product provides

The module calls these functions and nothing else of the host. A product that copies the file
provides them (Gangplank's own are in `Core/`):

| Function | What it must do |
|---|---|
| `Get-GangplankEnv` | Read `GANGPLANK_<NAME>` from the environment (Gangplank also reads the pre-rename `KEYSTONE_<NAME>`); `$null` when unset or blank |
| `Get-GangplankLocalSettings` / `Save-GangplankLocalSettings` | Load and save the per-user settings object that holds the `Intelligence` section (non-secret) |
| `Invoke-GangplankHttpRequest` | One HTTP call returning `{ Status; Headers; Text }`, no redirects across hosts, bounded retry for GET |
| `ConvertFrom-GangplankApiResponse` | Turn a response into data, or throw a coded `CODE|message` error without the body |
| `Get-GangplankProviderErrorCode` | Map an HTTP status to a code such as `AUTH_REJECTED` or `NOT_FOUND` |
| `Get-GangplankSafeUrl` | A URL without its query string, safe for logs |
| `Get-GangplankAiToken` | The AI credential: environment, the product's store, or the vault |
| `Get-GangplankEnvironmentCredential` / `Get-GangplankStoredCredential` | The AI token from the environment, and from the product's own store |
| `Get-GangplankCredentialStatus` | Whether an AI credential is configured (never the value) |
| `Write-GangplankAudit` | Record a settings change (never a token) |

In another product the `Gangplank` in the names stays, so the file is the same everywhere; the
product supplies thin functions with those names.

## What the module decides

- The endpoint comes from the environment (`GANGPLANK_AI_URL`, `LLM_URL`, `OPENAI_BASE_URL`), then
  the saved setting, then the built-in default. Every address passes the same checks: HTTPS (plain
  http only for this PC), no embedded credentials, and the administrator allowlist when set.
- A loopback endpoint needs no token; any other endpoint does.
- Models that are not for chat (embedding, speech, image) are never offered.

## What it does not know

Gangplank's session, providers, jobs and screens. The contract test fails if the file starts
referring to them, or if the list of host functions above changes without this guide and the
version being updated.

## Adopting it elsewhere

1. Copy `Core/Intelligence.ps1` and `tests/Intelligence.Tests.ps1`.
2. Provide the functions in the table.
3. Run the copied tests, then `tests/IntelligenceContract.Tests.ps1` adapted to the product's paths.

Not done here: the copies in Halyard and Shellback. Those are separate pull requests in their repositories.
