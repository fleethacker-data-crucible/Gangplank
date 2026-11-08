# Agent notes

- No compatibility aliases. When a name changes, the old name is removed, never kept as a fallback. Local data is renamed by hand once.
- Lazarette is read only through the names in Lazarette `docs/INTEGRATION.md` and `docs/FLEET-ITEMS.md` (`lib\Lazarette.ps1`, `Unlock-LazaretteVaultInteractive`, `Get-LazaretteSecret`, ...). Don't add other loaders, search paths or environment variables. Exception: a Lazarette Lite folder (LazaretteLite.psd1 at the folder root, lib\Lazarette.ps1 present) is a permitted Lazarette-path target under the same opt-in rule (GANGPLANK_LAZARETTE_PATH, or Integrations Lazarette.Enabled + Lazarette.Path only; generic LAZARETTE_PATH still never enables it). Lite is secret-only (no -Field, no TOTP, no attachments, no history) and its unlock is a no-op, so the passphrase + second-factor gate is dropped while Lite answers.
- Commit only as the configured git identity. Don't set `user.name` or `user.email`, don't pass `--author`, and don't add `Co-Authored-By` or "Generated with" lines or name any tool in commit messages or PR text.
- Windows PowerShell 5.1 syntax in `.ps1` files.
