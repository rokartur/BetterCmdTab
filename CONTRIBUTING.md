# Contributing to BetterCmdTab

Thanks for taking the time to contribute. Issues and pull requests are both welcome — bug reports, feature ideas, and code changes alike.

## Ground rules

- Keep the app feeling native. AppKit only, no SwiftUI, no Catalyst, no third-party UI frameworks.
- No telemetry, analytics, or background network traffic. The only allowed network calls are GitHub Releases checks, and only when the user opts in.
- Minimum deployment target stays at macOS 13.0. Newer-OS features must be gated with `if #available` and ship a graceful fallback.
- Performance matters. Anything on the Cmd+Tab hot path needs to stay off the main thread or be measured.

## Project layout

The codebase is small. Read these first:

- `BetterCmdTab/Input/HotkeyTap.swift` — global event tap, runs on its own thread
- `BetterCmdTab/Switcher/SwitcherController.swift` — switcher state machine
- `BetterCmdTab/Switcher/SwitcherView.swift` — list and grid layout
- `BetterCmdTab/Switcher/SwitcherPanel.swift` — non-activating panel + active-state pinning
- `BetterCmdTab/Catalog/AppCatalog.swift` — AX-based app + window enumeration
- `BetterCmdTab/Catalog/AppCatalogCache.swift` — incremental cache, observers, MRU bumps
- `BetterCmdTab/Windows/Activator.swift` — activation, raise, close, hide, quit
- `BetterCmdTab/Windows/MRUTracker.swift` — most-recently-used app ordering
- `BetterCmdTab/Settings/` — native AppKit Settings window
- `BetterCmdTab/Updater/` — GitHub Releases updater and update window
- `BetterCmdTab/System/PrivateAPIs.swift` — private CGS / SkyLight glue, isolated for review

## Building

```bash
git clone https://github.com/rokartur/BetterCmdTab.git
cd BetterCmdTab
xcodebuild -scheme "BetterCmdTab Debug" -configuration Debug build
```

You need Xcode 16+ and the macOS 26 SDK installed. The Liquid Glass code paths are gated to macOS 26 — building against an older SDK still works, the app just falls back to NSVisualEffectView at runtime.

## Running tests

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test
```

Tests live under `BetterCmdTabTests/`. They cover pure logic — switcher metrics, row labelling, updater parsing, Liquid Glass selection. UI behavior is verified manually because the switcher needs a real WindowServer + Accessibility permissions.

## Pull request checklist

- The change builds clean with no new warnings.
- All existing tests still pass.
- New behavior comes with at least one test if it has any pure-logic surface.
- No commented-out code, no dead branches, no leftover `print` statements (use `os.Logger` via `Log.*`).
- Commit messages follow `type: short summary` (e.g. `fix: …`, `feat: …`, `perf: …`, `refactor: …`, `docs: …`, `chore: …`). Wrap the body at ~72 chars and explain *why*, not *what*.
- One logical change per PR. Split refactors out from behavior changes.

## Reporting bugs

Open an issue with:

1. macOS version (`sw_vers`)
2. BetterCmdTab version (menu bar → About)
3. Steps to reproduce — exact key sequence, which apps were open, which display you were on
4. What you expected vs. what happened
5. A short screen recording if the bug is visual (focus flicker, layout, glass rendering)

Crashes: attach the `.ips` from `~/Library/Logs/DiagnosticReports/` if there is one.

## Feature requests

Describe the workflow you want, not the implementation. "I want to filter the switcher by app category" is more useful than "add a category dropdown." Implementation can be debated; the underlying need is what drives the design.

## Security

If you find a vulnerability — anything that lets a third-party app read switcher state, intercept hotkeys, or escalate via the AX permission BetterCmdTab holds — please open a private security advisory on GitHub instead of a public issue.

## License

By submitting a contribution you agree that your work will be licensed under the project's [GPL v3](LICENSE).
