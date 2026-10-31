# ui-src: the typed UI source (first slice)

This folder is where the rebuilt Gangplank UI will live (roadmap items 8 and 9). It replaces
`web/` screen by screen; `web/` keeps working and stays the UI the host serves until a screen
has moved over.

## Decisions (made without asking; change them in a pull request if you disagree)

| Question | Choice | Why |
|---|---|---|
| Framework | Svelte 5 + TypeScript | Same as Lazarette, which already has the build, the Fleet tokens and the accessibility checks to copy. React 19 stays possible; the client below does not depend on it. |
| Styling | Tailwind CSS 4 with the Fleet tokens (`--fl-*`) | TechStack and `docs/UNIFIED-UI.md`; no raw colours. |
| Build output | `ui/dist` committed, with a staleness check | Gangplank has no build step on the workstation, so the built files must be in the repository (the Shellback pattern). |
| Loading | Everything bundled, strict CSP, no CDN | TechStack. |

## What is here now

- `src/api.ts`: a typed client for the host API with the same behaviour as `api()` and
  `runJob()` in `web/app.js`: client header, coded errors, job polling, progress and chunks, cancel.
  It uses only erasable TypeScript syntax, so Node runs it and its tests directly.
- `tests/api.test.ts`: the client against a scripted `fetch`.
- `tests/host.contract.test.ts`: the client against the real host and the synthetic GitHub.

```
node --test ui-src/tests/api.test.ts ui-src/tests/host.contract.test.ts
```

Needs Node 22.18 or later (type stripping). Nothing is installed.

## Not done

The Svelte project (`package.json`, Vite, Tailwind), any screen, and the `ui/dist` staleness
check. They need the packages installed on a build PC; this slice deliberately needs none.
