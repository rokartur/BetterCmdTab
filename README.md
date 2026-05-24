# BetterCmdTab

A fast, native Cmd+Tab replacement for macOS. Open source, free, no telemetry.

Built in Swift / AppKit. Designed for macOS 13–26+ with first-class Liquid Glass support on macOS 26.

---

## Why

macOS's built-in Cmd+Tab switches apps, not windows. Third-party alternatives either cost money (Witch, Contexts) or feel heavy and have not adopted Liquid Glass. BetterCmdTab is a single menu-bar agent that boots in milliseconds, draws with the system Liquid Glass material on macOS 26, and ships with no subscription, no license key, and no analytics.

## Features

- **Two layouts** — classic vertical list, or a grid of app icons with spatial arrow-key navigation.
- **Window-level switching** — `Cmd+\`` cycles the windows of the frontmost app. Works on every app, including non-AppKit apps (Ghostty, Alacritty, Wezterm).
- **Letter-prefix jump** — start typing the first letters of an app name to reorder the list and jump to the match.
- **Quick actions on the highlighted row** — quit, close window, minimize, hide, all without leaving the switcher.
- **Liquid Glass backdrop on macOS 26**, NSVisualEffectView fallback below.
- **Multi-monitor aware** — opens on the screen with the cursor; repositions when displays connect, disconnect, or change resolution.
- **Shift+tap** to step backwards without holding Tab.
- **Menu bar agent** — no dock icon, no main window, no Electron.

## Performance

- Hotkey event tap runs on a dedicated thread, so the first Cmd+Tab after launch is never blocked by main-thread work.
- Accessibility observers install off-main during boot.
- App catalog pre-warms in the background and serializes MRU bumps so the row order stays consistent on rapid Cmd+Tab presses.
- Windows sort by real WindowServer z-order, not stale AX guesses.

## Install

### Download

Grab the latest signed `.dmg` from the [Releases page](https://github.com/rokartur/BetterCmdTab/releases), open it, drag `BetterCmdTab.app` to `/Applications`, and launch.

On first launch macOS will ask for **Accessibility** permission — this is required for the global Cmd+Tab event tap and for reading window lists via the Accessibility API. Grant it under `System Settings → Privacy & Security → Accessibility`.

### Build from source

```bash
git clone https://github.com/rokartur/BetterCmdTab.git
cd BetterCmdTab
xcodebuild -scheme "BetterCmdTab Release" -configuration Release build
```

Requires Xcode 16+ and the macOS 26 SDK to build the Liquid Glass code paths. The deployment target is macOS 13.0 — older SDKs fall back to NSVisualEffectView automatically.

## Shortcuts

While Cmd is held:

| Shortcut | Action |
|----------|--------|
| `Cmd + Tab` | Next app |
| `Cmd + Tab, Shift ` | Previous app |
| `` Cmd + ` `` | Next window of current app |
| `` Cmd + Shift + ` `` | Previous window of current app |
| `Cmd + ←` / `Cmd + →` | Spatial navigation (Grid layout) |
| `Cmd + ↑` / `Cmd + ↓` | Vertical navigation |
| `Cmd + <letter(s)>` | Jump to app starting with that letter |
| `Cmd + Q` | Quit the highlighted app |
| `Cmd + W` | Close the highlighted window |
| `Cmd + M` | Minimize the highlighted window |
| `Cmd + H` | Hide / unhide the highlighted app |
| `Cmd + Esc` | Cancel switcher without activating anything |
| `Release Cmd` | Activate the highlighted row |

## Requirements

- macOS 13.0 (Ventura) or newer
- Accessibility permission

Liquid Glass rendering requires macOS 26. On 13–15 you get NSVisualEffectView with `.hudWindow` material, which looks similar enough.

## Privacy

BetterCmdTab does not collect, transmit, or store any data. There is no telemetry, no crash reporting service, no analytics SDK, and no account. The only network requests it makes are to `api.github.com` and `github.com` when checking for updates, and only when you ask it to.

## Contributing

Issues and pull requests welcome. The codebase is small enough to read in an afternoon — the entry points are:

- `BetterCmdTab/Input/HotkeyTap.swift` — global event tap and key handling
- `BetterCmdTab/Switcher/SwitcherController.swift` — switcher state machine
- `BetterCmdTab/Switcher/SwitcherView.swift` — list and grid layout
- `BetterCmdTab/Catalog/AppCatalog.swift` — AX window enumeration
- `BetterCmdTab/Windows/Activator.swift` — bring-to-front, raise, focus

Run the test suite with:

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test
```

## License

GPL v3. See [LICENSE](LICENSE).

BetterCmdTab is licensed under the GNU General Public License v3.0. You are free to use, study, modify, and redistribute it — including for commercial purposes — but any distributed derivative work must also be released under GPL v3 with full source code. This keeps the project and any fork of it open, forever.

## Credits

Built by [@rokartur](https://github.com/rokartur). Inspired by [AltTab](https://alt-tab.app/), [Witch](https://manytricks.com/witch/), and [Contexts](https://contexts.co/).
