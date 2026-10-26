# Repo README Standard

**Version 0.1 · 2026-10-25 · Status: proposed, not enforced**

This file is identical in every repo that carries it. Change it in one repo's PR, then copy it unchanged to the
others and bump the version. It expands section 8 of `UNIFIED-UI.md` (README) for Fleet repos and works on its own
for every other repo.

Requirement words: **MUST** is required to call a README aligned. **SHOULD** is expected unless there's a stated
reason not to. **MAY** is optional. Sections marked *(Fleet)* apply only to Fleet app repos.

---

## 1. What a README is for

A README answers, in this order: **what is it, how do I run it, is it safe, where do I go next.** Everything else
(architecture, operations, history, full feature lists) belongs in `docs/`. A reader should be able to start the app
from the first screen of the README.

## 2. Order of sections

| # | Section | Rule |
|---|---|---|
| 1 | Emblem | **MUST** *(Fleet)*, centered, theme-aware (section 3). Other repos **MAY** use a logo the same way. |
| 2 | `# Name` | **MUST** be the display name exactly (`Eight Bells`, `Halyard Ballast`, `SnapShackle`), with no tagline in the heading. |
| 3 | One-line description | **MUST** be one sentence directly under the heading: what it does and for whom. Bold is optional. |
| 4 | Status line | **SHOULD** appear if the project isn't production software ("Engineering preview", "Prototype"), as one short line or callout. |
| 5 | The name | **MUST** *(Fleet)*: a short `## The name` section (or a `> **The name.**` callout) giving the double meaning and every former name. |
| 6 | Screenshot | **SHOULD** for apps with a UI: one screenshot of each theme, side by side, from `docs/`. |
| 7 | Quick start / Run it | **MUST** for anything you run: the launcher (`Launch-<App>.bat` for Fleet apps), what it needs on the machine (and what it doesn't: admin, installs, network), and how to stop it. Five steps or fewer. Build steps go in a separate "Build it" section or in `docs/`. |
| 8 | What it does | **SHOULD**: a short list or table of capabilities. Not a changelog. |
| 9 | Privacy and security in short | **MUST** for apps that handle user data, credentials or the network: one paragraph or a few bullets, linking to the full doc. |
| 10 | Documentation | **SHOULD**: links to `docs/` (user guide, architecture, operations, development) and to `TechStack` / `UNIFIED-UI.md` where present. |
| 11 | License | **MUST**: a `## License` line naming the license, and a matching `LICENSE` file at the root. |

Sections 8 to 10 **MAY** change order or merge. Nothing else **SHOULD** come before Quick start.

## 3. Graphics

Every image in a README **MUST** read well in both GitHub's light and dark themes.

### Emblem *(Fleet)*

The full-detail emblems (`emblem-light.png`, `emblem-dark.png`) are the originals. **Never replace or redraw them.**
The current ones have a solid background (parchment on the light version, navy on the dark one), so embedding only
the light one shows a bright square on a dark page. Use one of these, in order of preference:

1. **`<picture>` with both originals (MUST, unless 2 or 3 applies).** GitHub shows the one that matches the
   reader's theme:

   ```html
   <p align="center">
     <picture>
       <source media="(prefers-color-scheme: dark)" srcset="assets/brand/emblem-dark.png">
       <img src="assets/brand/emblem-light.png" width="280" alt="Halyard emblem: a mast and signal flags inside a brass compass ring">
     </picture>
   </p>
   ```

2. **Transparent-background versions (MAY).** `emblem-light-transparent.png` and `emblem-dark-transparent.png`,
   cut out from the originals with the background removed and nothing else changed. They go in `assets/brand/`
   *next to* the originals, and are used in the same `<picture>` block. They sit on the page instead of in a box.
3. **A theme-aware SVG (MAY).** An `emblem.svg` whose colors switch with an internal
   `@media (prefers-color-scheme: …)` rule, as Lazarette's does. Only when the SVG is the original artwork.

Other image rules:

- **Width:** 220 to 280 px for the emblem.
- **Alt text:** **MUST** describe the emblem ("Lazarette emblem: a brass-banded chest inside a compass ring"),
  not just repeat the name.
- **Screenshots:** **SHOULD** show both themes; take them with demo data only.
- **Diagrams:** **SHOULD** use a transparent background or a `<picture>` pair, the same as the emblem.
- **Hosting:** **MUST** reference files in the repo by relative path. Images hot-linked from other repos break when
  those repos move or go private.
- **Badges:** **SHOULD NOT** be used. If used, they come from a local SVG, not a badge service.

## 4. Writing

- **Plain words, short sentences**, second person ("double-click", "you need"). Explain jargon the first time.
- **Length:** **SHOULD** stay under about 150 lines. Move long sections to `docs/` and link them.
- **No history in the README:** rename notes ("Renamed to X in v0.12"), release notes and per-version feature
  lists go in `CHANGELOG.md`. The README keeps only the current state plus the former names in "The name".
- **No sensitive content:** no internal hosts, real names in examples, `.mil` addresses or secrets.
- **Code blocks** name their language (`powershell`, `bat`, `text`).
- **Links** are relative inside the repo.

## 5. Template

```markdown
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/emblem-dark.png">
    <img src="assets/brand/emblem-light.png" width="280" alt="<App> emblem: <what it shows>">
  </picture>
</p>

# <App>

<One sentence: what it does and for whom.>

## The name

<The double meaning in one or two sentences.> Formerly <Old name>.

| Night watch (dark) | Chart room (light) |
| --- | --- |
| ![<App> in the dark theme](docs/screenshot-dark.png) | ![<App> in the light theme](docs/screenshot-light.png) |

## Run it

1. <Get the release zip / clone>.
2. Double-click `Launch-<App>.bat`. No admin rights or installs needed.
3. <What happens: the browser opens at 127.0.0.1:<port>.>
4. To stop: <close the tab / End session / Stop-<App>.ps1>.

## What it does

- <Capability>
- <Capability>

## Privacy and security

<One paragraph. Link docs/SECURITY.md.>

## Documentation

- [User guide](docs/USER-GUIDE.md) · [Architecture](docs/ARCHITECTURE.md) · [Development](docs/DEVELOPMENT.md)
- Stack: [TechStack](TechStack) · Look: [UNIFIED-UI.md](docs/UNIFIED-UI.md)

## License

MIT. See [LICENSE](LICENSE).
```

## 6. Checklist

Copy into the repo's tracking issue.

- [ ] Emblem at the top in a `<picture>` block (or transparent / theme-aware SVG); originals unchanged *(Fleet)*
- [ ] Emblem alt text describes it
- [ ] `# Name` is the display name; one-line description under it
- [ ] "The name" with the double meaning and former names *(Fleet)*
- [ ] Run it / Quick start before any other content section; five steps or fewer
- [ ] Privacy and security in short (apps that handle data)
- [ ] Documentation links
- [ ] `## License` and a root `LICENSE` file
- [ ] Under ~150 lines; no rename history or release notes
- [ ] Every image is in the repo, relative path, readable in both themes
