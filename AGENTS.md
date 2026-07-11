## Project priority — performance first

Performance, optimization, and minimal resource usage are the top priority for every change
in this project. It is a ⌘Tab hot-path app: prefer the solution that uses the least CPU,
memory, and energy, keep work off the main thread (or measure it), avoid allocations and
polling on hot paths, and don't add a dependency or background task when a lighter approach
works. When two designs are equally correct, ship the cheaper one.

## Tooling policy — reach for caveman first

Always use caveman tooling whenever the job fits — it is the first choice, not a fallback.
Only drop to a lower tier when the caveman tool structurally can't do the job (not merely
because it feels faster).

1. **cavecrew subagents** over inline reading/editing/reviewing and over vanilla
   `Explore`/`Agent`. Their output is caveman-compressed (~60% smaller back into main
   context), so prefer them whenever the job fits their scope:
   - `cavecrew-investigator` — locate code ("where is X", "what calls Y", "map this dir").
     Use instead of fanning out `Grep`/`Glob`/`Explore` yourself.
   - `cavecrew-builder` — bounded 1–2 file edit (typo, single-function rewrite, rename,
     format-preserving tweak). It **hard-refuses 3+ file scope and new features** — that
     refusal is the signal to fall back, not a reason to avoid trying it first.
   - `cavecrew-reviewer` — diff / branch / file review, one line per finding.
2. **caveman skills** for their specific jobs: `/caveman-commit` (commit messages),
   `/caveman-review` (PR feedback), `/caveman-compress` (shrink memory files).
3. **Fall back** to native `Read`/`Edit`/`Write`/`Grep`/`Glob`, `Explore`, or a
   `general-purpose` Agent only when the tiers above can't cover the work — e.g. a
   cross-file (3+) refactor that `cavecrew-builder` refuses, a new feature spanning many
   files, or multi-step research no single cavecrew role handles.

Caveman *response mode* is active this session (terse output). Keep code, commits, PRs,
and security/irreversible-action notes in normal prose.

## Build / test / run

Xcode 16+ and the macOS 26 SDK are required (Liquid Glass paths are SDK-gated; deployment
target is macOS 13.0, which falls back to `NSVisualEffectView` at runtime). Two schemes
exist: `BetterCmdTab Debug` and `BetterCmdTab`.

```bash
# Build
xcodebuild -scheme "BetterCmdTab Debug" -configuration Debug build
xcodebuild -scheme "BetterCmdTab" -configuration Release build   # ships Liquid Glass

# Test (whole suite)
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test

# Single test class / method
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' \
  test -only-testing:BetterCmdTabTests/FuzzyMatchTests
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' \
  test -only-testing:BetterCmdTabTests/FuzzyMatchTests/noMatch
```

Tests use **Swift Testing** (`import Testing`, `@Suite`/`@Test`), not XCTest — there are
no `testXxx()` methods, so select a single case by its Swift function name (e.g. `noMatch`,
`appNameSubsequence`), not by a `test`-prefixed name.

Tests cover **pure logic only** (switcher metrics, row labels, catalog filtering, fuzzy
match, updater parsing, Liquid Glass selection, settings portability). UI behavior is
verified manually — the switcher needs a live WindowServer + Accessibility permission, so
the UI test surface fails in headless/CI and is not part of the unit run.

## Release / version

```bash
scripts/set_version.sh 26.5               # set MARKETING_VERSION, auto-commits (chore: bump …)
scripts/set_version.sh --show             # print current version & build
scripts/build_release.sh                  # build + sign + notarize + dmg/zip → build/release/
scripts/build_release.sh --beta           # beta build, auto-detects next beta.N from GitHub tags
scripts/build_release.sh --auto-release   # after notarize, create the GitHub release (needs --notes or prompts)
scripts/build_release.sh --skip-notarization   # dev build, no notarize (refuses --auto-release)
scripts/update-packages.sh                # bump SPM deps (clears Package.resolved, re-resolves)
```

`build_release.sh` stamps a fresh `CURRENT_PROJECT_VERSION` on every build (skip with
`--skip-build-bump`); only the app target's version moves, the test target keeps its own.
Signing/notarization needs the `Developer ID Application: Artur Rok (N529W98U62)` certificate
and the `BetterCmdTabNotarization` notarytool keychain profile (see the script header).
`.github/workflows/sign-release.yml` runs signing in CI.

### Changelog format (the release body)

The changelog *is* the GitHub Release body (no `CHANGELOG.md`). Pass it to
`build_release.sh --auto-release --notes notes.md`, or write it after the fact with
`gh release create <tag> -R rokartur/BetterCmdTab --title "BetterCmdTab <version>" --notes-file notes.md`.
Tags carry a `v` prefix for stable releases (`v26.4.3`) and a bare `MAJOR.MINOR-beta.N` for
prereleases (`26.0-beta.1`, published with `--prerelease`); `MAJOR` tracks the macOS year.

Match the established BetterCmdTab body shape — this is an end-user app, so bullets are
**user-facing and outcome-first**, not internal symbol names:

- **First line** is `## Highlights` — a one/two-sentence summary of what the release delivers.
- Then `### Added`, `### Changed`, `### Fixed`, `### Removed` as they apply (omit empty sections).
- Each bullet describes the observable behavior change for the user — what now works / changed,
  not which type was renamed. Exclude `chore`/`refactor`/`build`/`test`/`ci`/`docs`-only changes.
- End with a compare footer for any release with a predecessor (blank line before it):
  ```
  **Full changelog:** https://github.com/rokartur/BetterCmdTab/compare/<prev-tag>...<tag>
  ```

(Library packages in the `Better*` family — `BetterSettings`, `BetterUpdater`, etc. — use the same
structure but with technical, API-level bullets; see their `CLAUDE.md`.)

## Architecture

macOS menu-bar (`.accessory`) app, **AppKit only** — no SwiftUI, no Catalyst, no
third-party UI frameworks. `AppDelegate` (`App/AppDelegate.swift`) wires everything at
launch and owns the single `SwitcherController`. Three SPM packages, all first-party
(`rokartur/*`): `BetterSettings`, `BetterUpdater`, `BetterShortcuts` (`swift-argument-parser`
shows up in the resolved graph only as their transitive dep — not used by the app directly).

`AppDelegate.main()` sets `.accessory` (no Dock icon) and calls `app.run()`, but the
`SwitcherController` does **not** boot until Accessibility is trusted: `AccessibilityWaiter`
polls `AXIsProcessTrusted()` and then calls `bootController()`. A switcher that "does
nothing" almost always means the AX permission was not granted.

Data + control flow on the ⌘Tab hot path:

- **Input** (`Input/`) — `HotkeyTap` is a CGEvent tap on its **own thread** that detects
  the ⌘Tab chord and suppresses the native switcher. The tap goes deaf under **Secure
  Event Input** (password fields), so `CarbonHotkeyTrigger` (Carbon `RegisterEventHotKey`)
  is the survivor trigger that still opens the panel in that state. `DirectActivation` /
  `ScopedSwitch` handle
  per-app hotkeys and scoped cycling without opening the panel. `SwipeTrigger` +
  `SpaceSwipeSuppressor` drive the three-finger trackpad gesture. `WindowManagement` moves
  windows across displays.
- **Catalog** (`Catalog/`) — `AppCatalog` enumerates apps/windows via the Accessibility
  API. `AppCatalogCache` keeps an incremental cache fed by AX observers and MRU bumps so
  the panel opens instantly. `CatalogFilter` applies pin/hide/scope rules; `IconCache` and
  `InstalledAppsIndex` back icons and the launch-any-app search.
- **Switcher** (`Switcher/`) — `SwitcherController` is the state machine (selection,
  letter-jump, fuzzy search, tab drill-in). `SwitcherPanel` is the non-activating panel.
  `SwitcherView` lays out the three layouts (list / grid / window previews) via the
  per-layout item views. `WindowThumbnailCache` backs preview thumbnails; `TabStripView` +
  `Windows/BrowserTabs` implement the `\` tab drill-in.
- **Windows** (`Windows/`) — `Activator` performs activate/raise/close/hide/quit.
  `MRUTracker` / `WindowMRUTracker` order apps and windows by recency;
  `RecentlyClosedStore` powers reopen-recently-closed; `WindowEnumerator` lists windows.
- **System** (`System/`) — `PrivateAPIs` isolates all private CGS/SkyLight glue (kept in
  one file for review). `AccessibilityCheck` gates on the AX permission. `Log` is the
  `os.Logger` wrapper — use `Log.*`, never `print`. Plus audio-activity, Dock-badge,
  symbolic-hotkey-guard, and launch-at-login helpers.
- **Settings** (`Settings/`) — native AppKit settings window, one view controller per pane
  (General, Switcher, Appearance, Apps, Shortcuts, Privacy, Experimental, About).
  Fragile/new features go behind the off-by-default **Experimental** pane.

## Preferences, persistence & i18n

- **Preferences** — `App/Preferences.swift` is a `@MainActor` `ObservableObject` singleton
  (`Preferences.shared`) whose `@Published` properties persist to `UserDefaults` via `didSet`.
  All keys live in a `Keys` enum under the `"Switcher."` prefix. Hot-path consumers
  (`CatalogFilter`, `SwitcherController`) read some keys (sort order, app exceptions,
  expand-tabs) **directly off the main actor** from `UserDefaults`, so the key strings are
  the contract — don't rename one without updating both sides.
- **Portability** — `App/SettingsPortability.swift` exports/imports the whole `Switcher.*`
  namespace as a versioned `.cmdtab` JSON file (`schemaVersion`, UTI
  `pro.bettercmdtab.settings`). Import is partial (absent keys keep their current value) and
  calls `reloadFromDefaults()` to refresh live subscribers.
- **Localization** — user-facing strings use `String(localized: "…")` and live in the
  version-controlled `BetterCmdTab/Localizable.xcstrings` (native Xcode string catalog,
  macOS 13+). Enum display names (layout mode, accent, etc.) are localized too.

## Running locally

Run the `BetterCmdTab Debug` scheme from Xcode. The app is `.accessory` — no Dock icon, it
lives in the menu bar. On first launch grant **Accessibility** under System Settings →
Privacy & Security → Accessibility, then quit/relaunch (or wait for `AccessibilityWaiter`
to pick it up). Without that permission the switcher never boots and ⌘Tab does nothing.

## Conventions (from CONTRIBUTING.md)

- AppKit only; no telemetry/analytics/background network. Only allowed network calls are
  opt-in GitHub Releases update checks.
- Deployment target stays macOS 13.0. New-OS features must be `if #available`-gated with a
  graceful fallback.
- Hot-path work (anything on ⌘Tab) stays off the main thread or must be measured.
- Logging via `os.Logger` through `Log.*` — no leftover `print`.
- Commits: `type: short summary` (`fix:`/`feat:`/`perf:`/`refactor:`/`docs:`/`chore:`),
  body wrapped ~72 chars explaining *why*. One logical change per PR.
- New pure-logic behavior ships with at least one test.

## web/

Marketing site (Vite + React 19 + TanStack Router, bun/tsc build, oxlint/oxfmt). Separate
from the app; touch it only for the landing page, not app behavior.
