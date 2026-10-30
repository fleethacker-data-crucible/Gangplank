# Development branch reconciliation

2026-10-30

Both retired-terms branches already have their runtime changes on main: local phoenix-lai default, configured/allowlisted GitLab hosts, legacy credential aliases and data-marking checks. Preserve the newer UTF-8 BOM and equivalent literal-safe regex in Sentinel, the credential tests that also clear LLM_TOKEN and OPENAI_API_KEY, and the privacy section. Update the stale TechStack inventory rows to match the current configuration code. Merge the separate screenshot/walkthrough work normally. `standards/retired-terms` is an ancestor of `sync/retired-terms`.
