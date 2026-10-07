Cheapest wins: this app lives on the ⌘Tab hot path, so when two designs are equally correct,
ship the one that costs less CPU, memory and latency.

Gotchas no file in the repo confesses:

- The switcher boots only once Accessibility is trusted, so no unit test reaches it, and a
  running app whose ⌘Tab does nothing is missing that grant.
- Quit the app with `osascript -e 'quit app "BetterCmdTab Debug"'`. A signal (`pkill`, `kill`)
  skips `SymbolicHotkeyGuard`'s restore, so native ⌘Tab stays off until the app launches again.
- Swift Testing cases are selected by bare function name
  (`-only-testing:BetterCmdTabTests/FuzzyMatchTests/noMatch`); there is no `test` prefix.
- Building needs the macOS 26 SDK: the Liquid Glass panel compiles against `NSGlassEffectView`
  with no `#if`, and `if #available` falls back to `NSVisualEffectView` on macOS 13 to 15.

Read before editing:

- `CODING_STANDARDS.md` for any change under `BetterCmdTab/`.
- `ARCHITECTURE.md` (what crosses between folders) before touching `Input/`, `Catalog/`,
  `Switcher/`, `Windows/`, `App/Preferences.swift` or `App/ConfigFile.swift`.
- `docs/CONTRIBUTING.md` before touching `web/` or `docs/`.
- `CONTRIBUTING.md` for build and test commands and the PR process.
