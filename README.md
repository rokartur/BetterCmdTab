<div align="center">

<img src="https://github.com/user-attachments/assets/3e4bbb67-ef7d-4619-8068-1458d8460331" width="160" height="160" alt="BetterCmdTab" />

# BetterCmdTab

**The ⌘+Tab macOS deserves.**

Fast · Native · Liquid Glass · Zero telemetry · Free forever

[![image](https://img.shields.io/badge/Download_Latest_Release-F5F5F4?style=for-the-badge&logo=apple&logoColor=black)](https://github.com/rokartur/BetterCmdTab/releases/latest)

<p>
  <a href="https://github.com/rokartur/BetterCmdTab/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/rokartur/BetterCmdTab?include_prereleases&style=for-the-badge&label=release&color=white"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13.0+-000?style=for-the-badge&color=white">
  <a href="https://github.com/rokartur/BetterCmdTab/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/rokartur/BetterCmdTab/total?style=for-the-badge&color=white"></a>
</p>

<sub>
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#shortcuts">Shortcuts</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#contributing">Contribute</a>
</sub>

<br />
<br />

<img src="web/public/screenshots/preview.jpg" width="49%" alt="BetterCmdTab grid of app icons layout" />
<img src="web/public/screenshots/grid.jpg" width="49%" alt="BetterCmdTab grid of app icons layout" />
<img src="web/public/screenshots/list.jpg" width="49%" alt="BetterCmdTab classic vertical list layout" />

</div>

## Features

- **Three layouts** — classic list, grid of icons, or live window previews.
- **Window titles** — show each window's title under its icon in Grid and Previews.
- **Letter-prefix jump** — type a name to jump to it.
- **Search & launch** — press `/` to fuzzy-find, or launch any installed app.
- **Window switching** — `` ⌘+ ` `` cycles windows of the front app.
- **Tap or hold** — tap to switch instantly, hold to open the switcher.
- **Scroll to switch** — spin the mouse wheel to move through apps.
- **Recently closed** — reopen an app you just quit.
- **Minimized & hidden** — include minimized windows, hidden and windowless apps.
- **Pin & filter** — keep favorites up top, hide the rest.
- **Quick actions** — quit, close, minimize, maximize, hide inline.
- **Force quit** — `⌘+⌥+Q` SIGKILLs the highlighted app for when graceful Quit hangs.
- **Tab drill-in** — press `\` on a row whose window has tabs to pick a specific tab (Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Finder, Terminal, iTerm).
- **Move windows** — send the highlighted window to the next display.
- **App hotkeys** — assign a shortcut to focus or launch a chosen app.
- **Unread badges** — Dock badge counts, in the switcher.
- **Audio indicator** — flags apps playing sound.
- **Instant Spaces** — switch Spaces with no animation.
- **Current Space only** — show just the windows on the Space you're on.
- **Liquid Glass** — system material on macOS 26.
- **Theming** — panel opacity, corner radius, and a custom accent color.
- **Multi-monitor** — opens on the screen under the cursor.
- **Trackpad & haptics** — three-finger swipe to open the switcher or switch Spaces, optional feedback.
- **Hide from screen sharing** — keep the switcher out of screen recordings and shared screens. Needs macOS 14.6+.
- **Configurable** — custom hotkey, size, scale, layout.

## Install

### Download

Grab the latest signed `.dmg` from the [Releases page](https://github.com/rokartur/BetterCmdTab/releases), open it, drag `BetterCmdTab.app` to `/Applications`, and launch.

On first launch macOS will ask for **Accessibility** permission — this is required for the global ⌘+Tab event tap and for reading window lists via the Accessibility API. Grant it under `System Settings → Privacy & Security → Accessibility`.

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
| `Cmd + /` | Toggle the fuzzy search bar (filter running + launch installed apps) |
| `Cmd + Q` | Quit the highlighted app |
| `Cmd + Option + Q` | Force-quit the highlighted app (SIGKILL — for hung apps) |
| `Cmd + W` | Close the highlighted window |
| `Cmd + M` | Minimize the highlighted window |
| `Cmd + H` | Hide / unhide the highlighted app |
| `\` | Drill into the highlighted row's tab group (browsers, Finder, Terminal) |
| `Cmd + Option + ←/→/↑/↓` | Move the highlighted window to the adjacent display |
| `Cmd + Esc` | Cancel switcher without activating anything |
| `Release Cmd` | Activate the highlighted row |

The `Cmd + Tab` activation hotkey is configurable in Settings; you can also trigger the switcher with a three-finger trackpad swipe. Separately, you can assign a global shortcut per app slot to jump straight to (or launch) a chosen app without opening the switcher.

## Requirements

- macOS 13.0 (Ventura) or newer
- Accessibility permission

Liquid Glass rendering requires macOS 26. On 13–15 you get NSVisualEffectView with `.hudWindow` material, which looks similar enough.

## Privacy

BetterCmdTab does not collect, transmit, or store any data. There is no telemetry, no crash reporting service, no analytics SDK, and no account. The only network requests it makes are to `api.github.com` and `github.com` when checking for updates, and only when you ask it to.

## Contributing

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, build / test instructions, and PR guidelines.

## License

GPL v3. See [LICENSE](LICENSE).

BetterCmdTab is licensed under the GNU General Public License v3.0. You are free to use, study, modify, and redistribute it — including for commercial purposes — but any distributed derivative work must also be released under GPL v3 with full source code. This keeps the project and any fork of it open, forever.

## Credits

Built by [@rokartur](https://github.com/rokartur). Inspired by [AltTab](https://alt-tab.app/), [Witch](https://manytricks.com/witch/), and [Contexts](https://contexts.co/).
