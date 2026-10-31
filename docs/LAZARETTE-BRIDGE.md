# Lazarette credentials bridge

Gangplank can read its tokens from Lazarette, the suite's encrypted vault, so no token sits in a
config file, in the browser or on disk. It is **opt-in** and never looks for Lazarette on its own.

**Status:** built and tested offline against stub vaults and, when a checkout is present, against
Lazarette's real engine in its software (passphrase) profile. It has **not** been run against a smart-card
vault on the workstation (roadmap W1); that needs the real card and Lazarette's own smart card testing.

## Turning it on

1. Credentials → Lazarette vault → tick **Use Lazarette** and enter the Lazarette folder (the one that
   contains `lib\Lazarette.ps1`, or that engine's previous loader file). `GANGPLANK_LAZARETTE_PATH` does the same
   from the environment. Generic names such as `LAZARETTE_PATH` never enable it.
2. Restart Gangplank. It loads Lazarette once and runs Lazarette's own unlock
   (`Unlock-LazaretteVaultInteractive`) in the console, **once, at startup**. Gangplank never implements
   unlock itself and never unlocks from a browser request.

## What is read, and from where

| Purpose | Default Lazarette item | Override |
|---|---|---|
| GitHub | `github` | `GANGPLANK_LAZARETTE_ITEM_GitHub`, or the mapping in Credentials |
| GitLab | `gitlab` | `GANGPLANK_LAZARETTE_ITEM_GitLab`, or the mapping |
| AI (remote endpoints) | `ai-api-key` | `GANGPLANK_LAZARETTE_ITEM_AI`, or the mapping |

A token is looked up in this order: the environment variable, Gangplank's own store (sealed with Windows
DPAPI), then the Lazarette item. Items are read by name with `Get-LazaretteSecret`; the names the vault
offers come from `Get-LazaretteItemNames`.

## What Gangplank never does

- Return a token to the browser: the connection status lists item names only.
- Write a token to `credentials.json`, the settings file or the saved session state.
  `tests/LazaretteVaultFlow.Tests.ps1` scans those places for the tokens it read. The audit and run logs
  record item names and sources, never values, by design; that suite does not scan them.
- Unlock the vault a second time, or read it while it is locked.

## The Fleet router (Fairlead)

The built-in AI endpoint is the router on this PC, `http://127.0.0.1:8776/v1`. Gangplank does **not** read
the vault for a loopback AI endpoint, and it sends no `Authorization` header unless a token is saved.
That is enough while Fairlead has `requireClientKey` off for this machine. If Fairlead requires a client
key, create one with `fairlead clients add` and save it as the **AI** token in Settings (or set
`GANGPLANK_AI_TOKEN`). Reading that key from Lazarette is not wired yet.

## Tests

| Suite | What it proves |
|---|---|
| `tests/LazaretteContract.Tests.ps1` | The Lazarette integration contract against a stub engine: unlock once, no secret in the status |
| `tests/LazaretteIntegration.Tests.ps1` | Missing libraries are diagnosed, no unlock from request handlers, the catalog is unwrapped |
| `tests/LazaretteCoreOnly.Tests.ps1` | An older Lazarette without the optional helper still works |
| `tests/LazaretteNames.Tests.ps1` | Current and former function names, item-name overrides, legacy aliases |
| `tests/LazaretteVaultFlow.Tests.ps1` | Unlock once, tokens read by item name, the router skips the vault, nothing written to disk |
| `tests/LazaretteReal.Tests.ps1` | The real engine in the software profile (skipped when no checkout is found) |

## Not covered here

Smart-card unlock through the console, an organization vault, and the runner account's access to a
Lazarette vault are workstation items (roadmap W1 and W4).
