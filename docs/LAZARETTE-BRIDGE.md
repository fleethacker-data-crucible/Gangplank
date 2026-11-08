# Lazarette credentials bridge

Gangplank can read its tokens from Lazarette, the suite's encrypted vault, so no token sits in a
config file, in the browser or on disk. It is **opt-in** and never looks for Lazarette on its own.

**Status:** built and tested offline against stub vaults and, when a checkout is present, against
Lazarette's real engine in its software (passphrase) profile. It has **not** been run against a smart-card
vault on the workstation (roadmap W1); that needs the real card and Lazarette's own smart card testing.

## Turning it on

1. Credentials → Lazarette vault → tick **Use Lazarette** and enter the Lazarette folder (the one that
   contains `lib\Lazarette.ps1`, or that engine's previous loader file). `GANGPLANK_LAZARETTE_PATH` does the same
   from the environment. Generic names such as `LAZARETTE_PATH` never enable it. A Lazarette Lite folder works the same way: enter the Lite folder (the one that contains `LazaretteLite.psd1` and `lib\Lazarette.ps1`).
2. Restart Gangplank. It loads Lazarette once and runs Lazarette's own unlock
   (`Unlock-LazaretteVaultInteractive`) in the console, **once, at startup**. Gangplank never implements
   unlock itself and never unlocks from a browser request.

## What is read, and from where

| Purpose | Default Lazarette item | Override |
|---|---|---|
| GitHub | `github` | `GANGPLANK_LAZARETTE_ITEM_GitHub`, or the mapping in Credentials |
| GitLab | `gitlab` | `GANGPLANK_LAZARETTE_ITEM_GitLab`, or the mapping |

A token is looked up in this order: the environment variable, Gangplank's own store (sealed with Windows
DPAPI), then the Lazarette item (or the Lazarette Lite item, when the configured folder is Lite). Items are read by name with `Get-LazaretteSecret`; the names the vault
offers come from `Get-LazaretteItemNames`.

## What Gangplank never does

- Return a token to the browser: the connection status lists item names only.
- Write a token to `credentials.json`, the settings file or the saved session state.
  `tests/LazaretteVaultFlow.Tests.ps1` scans those places for the tokens it read. The audit and run logs
  record item names and sources, never values, by design; that suite does not scan them.
- Unlock the vault a second time, or read it while it is locked.

## Lazarette Lite fallback

A Lazarette Lite folder can stand in for Lazarette when the full vault is not
running or not present, under the same opt-in rule: point
`GANGPLANK_LAZARETTE_PATH` (or Integrations Lazarette.Enabled + Path) at the
Lite folder. Generic `LAZARETTE_PATH` never enables it, Lite or full.

What changes with Lite:

- No unlock prompt. Lite has no lock: its unlock is a no-op success, so the
  passphrase + second-factor gate is dropped while Lite answers. Anything the
  Windows user can read in Credential Manager, Gangplank can read.
- Secret-only. Lite keeps one secret per item: no custom fields, no TOTP, no
  attachments, no item history, and a 2,560-byte secret cap. Anything needing
  those still needs full Lazarette.
- The connection status reports `lazaretteKind: lite` and `lazaretteVersion:
  lite` (never `5` for Lite), so the UI and logs never mistake Lite for the
  full vault.

What does not change: the lookup order (environment, then Gangplank's own DPAPI
store, then the Lazarette/Lite item), the item names (`github`, `gitlab`,
`data-platform-api` and their `GANGPLANK_LAZARETTE_ITEM_*` overrides), and the
rules that no token ever goes to the browser, the log or the audit trail. AI
still goes to Fairlead with the `Fairlead/Gangplank` Credential Manager key;
Lite is never consulted for it.

## The Fleet router (Fairlead)

Gangplank does **not** read the vault for AI. Every AI request goes to Fairlead on this PC, and the client key for it
comes from Windows Credential Manager (`Fairlead/Gangplank`), installed by Fairlead. See the README for the setup.

## Tests

| Suite | What it proves |
|---|---|
| `tests/LazaretteContract.Tests.ps1` | The Lazarette integration contract against a stub engine: unlock once, no secret in the status |
| `tests/LazaretteIntegration.Tests.ps1` | Missing libraries are diagnosed, no unlock from request handlers, the catalog is unwrapped |
| `tests/LazaretteCoreOnly.Tests.ps1` | An older Lazarette without the optional helper still works |
| `tests/LazaretteNames.Tests.ps1` | Lazarette function names, item-name overrides, and that no other name or variable is read |
| `tests/LazaretteVaultFlow.Tests.ps1` | Unlock once, tokens read by item name, the router skips the vault, nothing written to disk |
| `tests/LazaretteReal.Tests.ps1` | The real engine in the software profile (skipped when no checkout is found) |

## Not covered here

Smart-card unlock through the console, an organization vault, and the runner account's access to a
Lazarette vault are workstation items (roadmap W1 and W4).
