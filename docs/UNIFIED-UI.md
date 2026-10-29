# Fleet Unified UI Requirements

**Version 0.1 · 2026-10-25 · Status: proposed**

This file is identical in every Fleet repo. Change it in one place and copy it to all the others; never edit a single repo's copy on its own. When the `fleet-design` repo exists, it becomes the source of truth and this file points there.

The Fleet apps should look like one family, not one app. They share a palette, type, shell, components and brand frame. Each keeps its own layout, workflow and one signature accent color.

Requirement words: **MUST** is required to call an app aligned. **SHOULD** is expected unless there's a stated reason not to. **MAY** is optional.

---

## 1. The Fleet

| App | Repo | Formerly | Job | Stack today | Port |
| --- | --- | --- | --- | --- | --- |
| Scrimshaw | Scrimshaw | (new) | Storyline-style course authoring | New | 8775 |
| Lazarette | Lazarette | ARC | Encrypted single-user vault | Svelte 5 + Tailwind 4 | 8765 |
| Halyard | Halyard | previous name | Product-owner backlog assistant | React + Tailwind, .NET engine | 8773 |
| Halyard Ballast | Halyard-Ballast | previous name | Halyard's write-only sandbox repo | No UI | — |
| Shellback | Shellback | Synapse | Workforce capability discovery | React 19 + Tailwind 4 | 8771 |
| SnapShackle | SnapShackle | CutterMk, Lasso, SnipHero | Screenshot and annotation studio | Plain HTML/JS | 8768 |
| Gangplank | Gangplank | Keystone | Git-free development workspace | Plain HTML/JS | 8769 |
| PacketRat | PacketRat | MailHawk | Outlook triage queue | Plain HTML/JS | 8766 |
| Eight Bells | Eight-Bells | LogHawk | Watchstanding log intelligence | Plain JS | 8774 |
| Capstan | Capstan | — | Screen recorder and video editor | React | 8772 |
| Bowerbird | bowerbird | — | File intelligence and renaming | Plain HTML/JS | 8767 |

Display names use the spelling in the first column (two words for Eight Bells and Halyard Ballast, one word everywhere else).

---

## 2. Principles

1. **Family, not clones.** Same palette, type, shell and components; different layouts and workflows.
2. **Local-first, offline, no CDN.** Every asset (CSS, fonts, icons, emblem) ships inside the repo. No runtime network requests for UI.
3. **Windows-native first.** Prefer fonts and behaviors already on a Windows 10/11 workstation. Nothing to install, no admin rights.
4. **Roles, not colors.** Components use semantic tokens (`--fl-surface`), never raw hex values.
5. **Brand comes from the frame.** The Scrimshaw emblem sets the shared frame; each app's subject is its own.

---

## 3. Color tokens

### 3.1 Requirements

- **MUST** define colors only through the `--fl-*` tokens below. No raw hex, rgb or named colors in component styles.
- **MUST** ship both themes: **Night watch** (dark) and **Chart room** (light).
- **MUST** follow `prefers-color-scheme` by default, with a manual override via `data-theme="dark" | "light"` on `<html>`.
- **MUST** persist the manual choice under `<app>-theme` in `localStorage`, wrapped in try/catch. The app must render correctly if storage is unavailable.
- **SHOULD** use the accent for primary actions, active navigation and selection only. It is a signature, not a fill color.

### 3.2 Shared tokens

The role names follow Lazarette's existing token set. The values come from the Scrimshaw logo.

| Token | Night watch | Chart room | Use |
| --- | --- | --- | --- |
| `--fl-background` | `#071a26` | `#fbfaf2` | Page background |
| `--fl-sidebar` | `#0a2130` | `#f3efe2` | Sidebar |
| `--fl-surface` | `#0d2636` | `#ffffff` | Main content area |
| `--fl-card` | `#112d40` | `#ffffff` | Cards, panels |
| `--fl-popover` | `#14334a` | `#ffffff` | Menus, dialogs, tooltips |
| `--fl-muted` | `#183a52` | `#efe9d9` | Subtle fills, hover rows |
| `--fl-border` | `#24465e` | `#dcd3bd` | Dividers, input borders |
| `--fl-border-strong` | `#34597a` | `#c4b79a` | Emphasized dividers |
| `--fl-control-border` | `#5f8199` | `#8c8370` | Input and secondary-button borders (≥3:1) |
| `--fl-foreground` | `#f4ead6` | `#132633` | Body text (14.8:1 both themes) |
| `--fl-muted-foreground` | `#a9b4ba` | `#4f5d66` | Secondary text (8.4:1 / 6.5:1) |
| `--fl-brass` | `#c9a66b` | `#8a6b45` | Focus rings, dividers, the fleet mark |
| `--fl-success` | `#4fb386` | `#2f7d57` | Success states |
| `--fl-warning` | `#e0a443` | `#9a6412` | Warnings |
| `--fl-danger` | `#ef6a5a` | `#b8382b` | Errors, destructive actions |
| `--fl-info` | `#6aa7e0` | `#1f5fa3` | Informational |
| `--fl-accent` | per app | per app | Signature accent (3.3) |
| `--fl-accent-ink` | per app | per app | Text on an accent fill |

### 3.3 Signature accents

Every value below passes 4.5:1 against its theme's background, so it is safe for text and icons as well as fills.

| App | Night watch | Chart room | Meaning |
| --- | --- | --- | --- |
| Scrimshaw | `#f1e4c8` ivory | `#7d6a48` aged bone | The bone it is carved on |
| Lazarette | `#c9a66b` brass | `#8a6b45` brass | The lock on the chest |
| Halyard | `#3fb6a8` teal | `#0f766e` teal | Keeps its previous color |
| Shellback | `#5cf1cb` mint | `#0b7a62` mint | Keeps Synapse's color |
| SnapShackle | `#ef6a5a` signal red | `#b8382b` signal red | Annotation ink |
| Gangplank | `#c99566` teak | `#8b5a2b` teak | The plank |
| PacketRat | `#6aa7e0` post blue | `#1f5fa3` post blue | The mail |
| Eight Bells | `#d6a258` bell bronze | `#8f5e22` bell bronze | The ship's bell |
| Capstan | `#d9845a` copper | `#a14f28` copper | Winch drum and tape |
| Bowerbird | `#9b98f3` satin blue | `#4b45b8` satin blue | The satin bowerbird collects blue things |

SnapShackle's accent equals `--fl-danger`. SnapShackle **MUST** pair danger states with an icon and a label, so color is never the only signal.

---

## 4. Typography

- **MUST** use these stacks. Every face is built into Windows, so nothing is installed or downloaded.
  - Body: `"Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif`
  - Mono: `"Cascadia Mono", "Cascadia Code", Consolas, ui-monospace, monospace`
- **SHOULD** use a display serif only for the wordmark, page titles and empty-state headlines. Never use it for body text, tables or controls. The face is chosen in `fleet-design` and **MUST** be shipped as a vendored `woff2` under an open-font license (see Open decisions).
- **MUST** use this scale (px, at 100% zoom): 12 caption · 13 secondary · 14 body · 16 section title · 20 page title · 28 display. Body line height 1.5, headings 1.25.
- **MUST NOT** use Inter. It is not installed on Windows by default and silently falls back.

---

## 5. Layout and the shell

Every app with a UI uses the same three-part shell. The content area is the app's own.

```
┌────────────┬──────────────────────────────────────────────┐
│  Emblem    │  Header: page title · context · actions      │
│  Wordmark  ├──────────────────────────────────────────────┤
│            │                                              │
│  Nav       │  Content (the app's own layout)              │
│            │                                              │
│            │                                              │
├────────────┴──────────────────────────────────────────────┤
│ Status bar: ● engine · 127.0.0.1:port · session · version  │
└───────────────────────────────────────────────────────────┘
```

- **Sidebar MUST** be 240 px wide, collapsible to 64 px (icons only), with the app emblem and wordmark at the top and navigation below.
- **Header MUST** be 56 px tall, with the page title on the left and page actions on the right.
- **Status bar MUST** be 28 px tall and show, left to right:
  1. Engine state: a dot plus a word (Running, Stopping, Disconnected). Never color alone.
  2. The actual bound address, e.g. `127.0.0.1:8768`.
  3. Session state where it applies (Locked / Unlocked, signed-in account).
  4. App version.
- **MUST** use a 4 px spacing grid. Standard steps: 4, 8, 12, 16, 24, 32, 48.
- **MUST** use radii of 6 px (controls), 10 px (cards) and 14 px (dialogs).
- **SHOULD** keep shadows to one level for popovers and dialogs. Cards use borders, not shadows.
- **MUST** work from 1280 × 720 up without horizontal scroll. Narrower than 1024 px, the sidebar collapses automatically.

---

## 6. Components

Plain-HTML apps use these classes directly. Tailwind and component-framework apps **MUST** match the same appearance and behavior, and **SHOULD** use the same class names on root elements so the shared CSS can style them.

| Class | Element | Notes |
| --- | --- | --- |
| `.fl-btn` | Button | Variants `--primary` (accent fill), `--secondary` (border), `--ghost`, `--danger`. Height 32 px, 36 px for `--lg`. |
| `.fl-input` | Text input, select, textarea | 32 px tall, `--fl-control-border`, brass focus ring |
| `.fl-card` | Panel | `--fl-card` fill, 1 px `--fl-border`, 10 px radius, 16 px padding |
| `.fl-table` | Data table | Sticky header, 36 px rows, `--fl-muted` hover, numbers right-aligned in mono |
| `.fl-badge` | Status chip | Uses status tokens; always includes a text label |
| `.fl-toast` | Notification | Bottom right, above the status bar, auto-dismiss 5 s unless it is an error |
| `.fl-dialog` | Modal | 14 px radius, focus trapped, Esc closes, destructive actions need a confirm |
| `.fl-empty` | Empty state | Emblem subject in line art, display-serif headline, one primary action |
| `.fl-nav` | Sidebar navigation | Active item: accent text and a 3 px accent bar on the left |

### Icons

- **MUST** use Lucide (ISC license). Lazarette already uses it throughout. Ship the SVGs you use in the repo; no icon CDN.
- **MUST** draw icons at 16 px in controls and 20 px in navigation, 1.75 px stroke, `currentColor`.

---

## 7. Interaction and accessibility

- **MUST** meet WCAG 2.2 AA: 4.5:1 for text, 3:1 for icons and control borders. Text, accent, status and `--fl-control-border` tokens pass; `--fl-border` and `--fl-border-strong` are for decorative dividers only and MUST NOT be the sole outline of a control.
- **MUST** show a visible focus ring on every interactive element: 2 px `--fl-brass`, 2 px offset.
- **MUST** be fully usable by keyboard. Shortcuts are listed under a `?` help dialog.
- **MUST** use click targets of at least 32 × 32 px.
- **MUST** keep transitions at 200 ms or less and turn them off under `prefers-reduced-motion`.
- **MUST NOT** show invented or placeholder numbers as if they were real. A missing value renders as "—" with a hint on how to get it.

---

## 8. Brand

- **Emblem frame. MUST** use the Scrimshaw frame:
  - circular ink-dark-blue field with a thin brass ring
  - compass-point rays at 3 and 9 o'clock
  - an engraved-style subject that may break out of the circle

  The subject is the app's own.
- **Wordmark. MUST** be the display serif, all caps, dark blue on light and ivory on dark, with the compass-star divider between brass rules underneath.
- **Assets. MUST** live in `assets/brand/`:
  - `emblem.svg` or `emblem.png` (full emblem with wordmark)
  - `mark.svg` (icon only, simplified to read at 32 px)
  - `favicon.ico` (16, 32, 48)
  - `tray.ico` (16, 20, 24, 32) for apps with a tray icon
- **README. MUST** open with the emblem, the name, a one-line description, and a short "The name" note giving the double meaning and the former names.

---

## 9. Launch, ports and naming

- **MUST** launch from `Launch-<App>.bat` (e.g. `Launch-SnapShackle.bat`), with `Start-<App>.ps1` as the direct PowerShell entry point and `Stop-<App>.ps1` to stop every running instance.
- **MUST** try the app's registry port first (section 1). If it is taken, bind a free loopback port, open the browser at the address actually bound, and show it in the status bar. Never stop or take over another app's server.
- **SHOULD** stop the engine shortly after the last browser tab closes, with a `--stay` switch to keep it running. Lazarette and SnapShackle already do this.
- **MUST** name per-user data folders `%LOCALAPPDATA%\<App>` and prefix browser storage keys with the lower-case app name (`snapshackle-settings`).
- **MUST** migrate data from a former name's folder or keys on first launch, copying forward and leaving the original untouched.
- **Dev servers** (Vite and similar) MAY use any port. The registry applies to the shipped engine.

---

## 10. How each stack adopts this

**Plain HTML/JS** (SnapShackle, Gangplank, PacketRat, Eight Bells, Bowerbird):

```html
<link rel="stylesheet" href="vendor/fleet/fleet.css">
<html data-app="snapshackle">  <!-- sets --fl-accent for this app -->
```

**Tailwind 4** (Lazarette, Shellback, Halyard): map the tokens into the theme so utilities and Fleet classes agree.

```css
@import "../vendor/fleet/fleet.css";
@theme inline {
  --color-background: var(--fl-background);
  --color-surface: var(--fl-surface);
  --color-card: var(--fl-card);
  --color-border: var(--fl-border);
  --color-foreground: var(--fl-foreground);
  --color-muted-foreground: var(--fl-muted-foreground);
  --color-primary: var(--fl-accent);
  --color-primary-foreground: var(--fl-accent-ink);
}
```

**React without Tailwind** (Capstan): import `fleet.css` once at the root and use the `.fl-*` classes.

**No UI** (Halyard Ballast): only sections 8 (README) and 9 (naming) apply.

---

## 11. Adoption checklist

Copy into the repo's tracking issue.

- [ ] `vendor/fleet/` added at the current Fleet version
- [ ] All colors go through `--fl-*` tokens; no raw hex in components
- [ ] Night watch and Chart room both work; override and persistence work
- [ ] Type stacks and scale applied; no Inter
- [ ] Shell: sidebar, header and status bar match section 5
- [ ] Components match section 6; Lucide icons vendored
- [ ] Focus rings, keyboard use and contrast pass section 7
- [ ] Brand assets in `assets/brand/`; README header updated
- [ ] Launcher, port, data folder and storage keys follow section 9, with migration from former names
- [ ] Screenshot of both themes added to `docs/`

---

## 12. Open decisions

- Umbrella name for the collection (The Fleet, Shipyard, other).
- Display serif for wordmarks; it must be licensed for bundling.
- Whether internal code symbols are renamed too, or only user-facing names, files, paths and contracts.
- Lazarette vault format: keep `arc-vault-v5` as an internal ID, or bump to v6 with a v5 reader.
- Where `fleet-design` lives and who reviews changes to it.

---

## Changing this document

Propose changes in one repo's PR. Once agreed, copy the file unchanged into every Fleet repo and bump the version at the top. Every repo should carry the same version.
