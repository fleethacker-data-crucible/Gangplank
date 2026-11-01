# Shared AI module

`Core/Intelligence.ps1` sends a product's AI requests to Fairlead, the local model router. The product
holds no gateway address, provider token or model id: it calls one loopback address with a route name
(`auto` by default) and its own Fairlead client key, read from Windows Credential Manager
(`Fairlead/<AppName>`). Halyard and Shellback can use the same file.

This is **version 2.0.0** of the module. It is copied into each product, not forked: change it here,
bump the version, and copy it back. The version is the line `# Shared module. Gangplank Intelligence,
version X.Y.Z` at the top of the file; `tests/IntelligenceContract.Tests.ps1` checks that it matches
this guide.

## What a product provides

The module calls these functions and nothing else of the host. A product that copies the file
provides them (Gangplank's own are in `Core/`):

| Function | What it must do |
|---|---|
| `Invoke-GangplankHttpRequest` | One HTTP call returning `{ Status; Headers; Text }`, no redirects across hosts, bounded retry for GET |
| `ConvertFrom-GangplankApiResponse` | Turn a response into data, or throw a coded `CODE|message` error without the body |
| `Get-GangplankSafeUrl` | A URL without its query string, safe for logs |

In another product the `Gangplank` in the names stays, so the file is the same everywhere; the
product supplies thin functions with those names.

## What the module decides

- The address is `http://127.0.0.1:8776/v1/chat/completions`, or `GANGPLANK_FAIRLEAD_URL` when it
  is a loopback address. Anything else is refused.
- The route is `GANGPLANK_FAIRLEAD_MODEL`, default `auto`.
- The key is only ever read from Credential Manager. With no key the module says
  "Open Fairlead and install a key for Gangplank."
- Every request carries `X-Fairlead-Label: Gangplank` and `X-Fairlead-Privacy: local`.

## What it does not know

Gangplank's session, providers, jobs and screens. The contract test fails if the file starts
referring to them, or if the list of host functions above changes without this guide and the
version being updated.

## Adopting it elsewhere

1. Copy `Core/Intelligence.ps1` and `tests/Intelligence.Tests.ps1`.
2. Provide the functions in the table.
3. Run the copied tests, then `tests/IntelligenceContract.Tests.ps1` adapted to the product's paths.

Not done here: the copies in Halyard and Shellback. Those are separate pull requests in their repositories.
