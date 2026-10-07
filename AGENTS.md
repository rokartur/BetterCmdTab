## Project priority: performance first

This is a ⌘Tab hot-path app, so performance and minimal resource usage come first in every
change. When two designs are equally correct, ship the cheaper one.

Rules for app code (platform, hot path, logging, strings, preferences, tests, commits) live in
`CODING_STANDARDS.md`; read it before any change under `BetterCmdTab/`.

## Build / test / run

`CONTRIBUTING.md` has the build and whole-suite test commands and which suites need a live
WindowServer. To run one suite or case, address the Swift Testing function by its bare name
(`noMatch`, `appNameSubsequence`); there are no `testXxx()` methods:

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' \
  test -only-testing:BetterCmdTabTests/FuzzyMatchTests/noMatch
```

The switcher needs Accessibility permission, so that surface is verified manually and is not
part of the unit run.

## Release / version

`scripts/set_version.sh` and `scripts/build_release.sh` document their own flags in their
headers; the `release` skill is the runbook. `.github/workflows/sign-release.yml` runs signing
in CI. Tags are bare (`26.7`, `26.7-beta.3`); only historical stable tags through `v26.6.1`
carry a `v` prefix.

Homebrew's BrewTestBot autobumps both casks off their `livecheck` blocks, which read the
version out of the DMG *asset filename*, not the tag. Cask upkeep is limited to landing
template fixes in the upstream tap: a cask workflow here would race BrewTestBot and need a
token with push rights on a third-party repository.

### Changelog format (the release body)

The changelog *is* the GitHub Release body (no `CHANGELOG.md`). Section names, heading depth
and order come from `compose_release_notes_interactively` in `scripts/build_release.sh`. This
is an end-user app, so bullets are **user-facing and outcome-first**:

- **First line** is `## Highlights`, a one/two-sentence summary of what the release delivers.
- Each bullet describes the observable behavior change for the user, what now works or
  changed, not which type was renamed. Exclude `chore`/`refactor`/`build`/`test`/`ci`/`docs`-only
  changes.
- End with a compare footer for any release with a predecessor (blank line before it):

  ```
  **Full changelog:** https://github.com/rokartur/BetterCmdTab/compare/<prev-tag>...<tag>
  ```

(Library packages in the `Better*` family, `BetterSettings`, `BetterUpdater`, etc., use the same
structure but with technical, API-level bullets; see their `CLAUDE.md`.)

## Architecture

macOS menu-bar (`.accessory`) app. `AppDelegate` (`App/AppDelegate.swift`) wires everything at
launch and owns the single `SwitcherController`. Three SPM packages, all first-party
(`rokartur/*`): `BetterSettings`, `BetterUpdater`, `BetterShortcuts`.

`AppDelegate.main()` sets `.accessory` and calls `app.run()`, but the `SwitcherController` does
**not** boot until Accessibility is trusted: `AccessibilityWaiter` polls `AXIsProcessTrusted()`
and then calls `bootController()`.

Data + control flow on the ⌘Tab hot path:

- **Input** (`Input/`): `HotkeyTap` is a CGEvent tap on its **own thread** that detects
  the ⌘Tab chord and suppresses the native switcher. The tap goes deaf under **Secure
  Event Input** (password fields), so `CarbonHotkeyTrigger` (Carbon `RegisterEventHotKey`)
  is the survivor trigger that still opens the panel in that state. `DirectActivation` /
  `ScopedSwitch` handle per-app hotkeys and scoped cycling without opening the panel.
  `SwipeTrigger` + `SpaceSwipeSuppressor` drive the three-finger trackpad gesture.
  `WindowManagement` moves windows across displays.
- **Catalog** (`Catalog/`): `AppCatalog` enumerates apps/windows via the Accessibility
  API. `AppCatalogCache` keeps an incremental cache fed by AX observers and MRU bumps so
  the panel opens instantly. `CatalogFilter` applies pin/hide/scope rules; `IconCache` and
  `InstalledAppsIndex` back icons and the launch-any-app search.
- **Switcher** (`Switcher/`): `SwitcherController` is the state machine (selection,
  letter-jump, fuzzy search, tab drill-in). `SwitcherPanel` is the non-activating panel.
  `SwitcherView` lays out the three layouts (list / grid / window previews) via the
  per-layout item views. `WindowThumbnailCache` backs preview thumbnails; `TabStripView` +
  `Windows/BrowserTabs` implement the `\` tab drill-in.
- **Windows** (`Windows/`): `Activator` performs activate/raise/close/hide/quit.
  `MRUTracker` / `WindowMRUTracker` order apps and windows by recency;
  `RecentlyClosedStore` powers reopen-recently-closed; `WindowEnumerator` lists windows.
- **System** (`System/`): `PrivateAPIs` isolates all private CGS/SkyLight glue (kept in
  one file for review). `AccessibilityCheck` gates on the AX permission. `Log` is the
  `os.Logger` wrapper.
- **Settings** (`Settings/`): native AppKit settings window, ten panes registered in
  `SettingsCatalog` (General, Profiles, Shortcuts, Switcher, Controls, Tabs, Apps,
  Appearance, Privacy, About). One controller per pane, except that
  `SwitcherPanesViewController` backs Switcher/Controls/Tabs from one `Pane` parameter
  since they share every control and one `viewWillAppear` sync.

## Preferences & persistence

- **Preferences**: `App/Preferences.swift` is a `@MainActor` `ObservableObject` singleton
  (`Preferences.shared`) whose `@Published` properties persist to `UserDefaults` via `didSet`.
  All keys live in a `Keys` enum under the `"Switcher."` prefix. Hot-path consumers
  (`CatalogFilter`, `SwitcherController`) read some keys (sort order, app exceptions,
  expand-tabs) **directly off the main actor** from `UserDefaults`.
- **Portability**: `App/SettingsPortability.swift` exports/imports the whole `Switcher.*`
  namespace as flat prefix-free JSON (`.json`); import also accepts the legacy versioned
  `.cmdtab` envelope (`schemaVersion`, UTI `pro.bettercmdtab.settings`). Import is partial
  (absent keys keep their current value) and calls `reloadFromDefaults()` to refresh live
  subscribers. `App/ConfigFile.swift` two-way-syncs the same flat format with
  `~/.config/bettercmdtab/config.json` (`$XDG_CONFIG_HOME` honored) when that file exists:
  event-driven watcher + debounced write-back, dormant when absent (#117). It also writes a
  sidecar `schema.json` (referenced by the config's `$schema` key) generated from the live
  snapshot, types only, open-ended, so a new preference needs no schema edit.

## Running locally

Run the `BetterCmdTab Debug` scheme from Xcode. The app has no Dock icon; it lives in the
menu bar. On first launch grant **Accessibility** under System Settings → Privacy & Security →
Accessibility, then quit/relaunch (or wait for `AccessibilityWaiter` to pick it up). Without
that permission the switcher never boots and ⌘Tab does nothing.

## web/ and docs/

The public site, two separate static exports that share one origin: `web/` is the marketing
page at `/`, built with **TanStack Start** on Vite and prerendered (SSR at build time) to
`web/out`; `docs/` is the Fumadocs site built with **Next.js** and `basePath: '/docs'`.
`web/Dockerfile` merges the docs export into `web/out/docs` and serves it with `web/serve.ts`,
deployed on vexdock as `bettercmdtab.app`. Separate from the app; touch them only for the
site, not app behavior.

`web/serve.ts` keeps the GitHub Pages contract the site was built for: it serves files, 301s a
bare directory to its slashed URL, answers anything missing with `404.html`, and sets no header
a page could rely on. Anything that would be a server rule has to be a property of the built
tree instead:

- Every page is `<slug>/index.html` and the slashed URL is the one that exists: `docs/` sets
  Next's `trailingSlash: true`, `web/` gets it from TanStack Start's prerender, which writes
  subfolder indexes by default. Canonicals, the sitemap and internal links all use that form;
  the bare form is a 301 from `serve.ts`, and pointing at it wastes a hop. Two exceptions: bare
  `/docs`, which `serve.ts` serves from `docs/index.html` as the canonical docs home, and
  `web/out/404.html`, prerendered from the `/404` route with `autoSubfolderIndex: false`
  because `serve.ts` serves that exact filename for anything missing.
- `web/public/sitemap.xml` is hand-maintained. CI checks it both ways: every URL resolves to a real
  file, and every `docs/content/docs/*/*.mdx` is listed.
- Next writes an RSC payload twin (`index.txt`, `__next._full.txt`) beside every docs page holding
  that page's whole text. `serve.ts` sends no `X-Robots-Tag`, so `web/public/robots.txt` disallows
  `*.txt$` and re-allows the two `llms*.txt` files. Keep that block, or replace it with a header
  `serve.ts` sends.
