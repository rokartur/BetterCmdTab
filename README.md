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
- **Scoped shortcuts** — a global hotkey that opens the switcher pre-filtered to all windows, the current Space, the current app's windows, or minimized only.
- **Tap or hold** — tap to switch instantly, hold to open the switcher.
- **Scroll to switch** — spin the mouse wheel to move through apps.
- **Sort order** — order apps by recents (MRU), alphabetically, or launch order.
- **Recently closed** — reopen an app you just quit.
- **Minimized & hidden** — include minimized windows, hidden and windowless apps.
- **Pin & filter** — keep favorites up top, hide the rest.
- **Per-app rules** — hide an app, or have it ignore ⌘Tab always or only when fullscreen.
- **Quick actions** — quit, close, minimize, maximize, hide inline.
- **Hover actions** — quick-action buttons appear on hover: close, minimize, zoom, hide, quit, force-quit.
- **Force quit** — `⌘+⌥+Q` SIGKILLs the highlighted app for when graceful Quit hangs.
- **Tab drill-in** — press `\` on a row whose window has tabs to pick a specific tab (Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Finder, Terminal, iTerm).
- **Tabs as rows** — optionally surface each native or browser tab as its own row, not just behind the `\` peek.
- **Window management** — tile windows to halves or corners, maximize, or center with `⌃⌘` arrows; press the tile key again to cycle ½ → ⅔ → ⅓ widths.
- **Move windows** — send the highlighted window to the next display.
- **App hotkeys** — assign a global shortcut to focus or launch a chosen app (9 slots).
- **Unread badges** — Dock badge counts, in the switcher.
- **Audio indicator** — flags apps playing sound.
- **Instant Spaces** — switch Spaces with no animation.
- **Current Space only** — show just the windows on the Space you're on.
- **Secure-input survivor** — ⌘Tab and window management keep working even while a password field holds Secure Event Input.
- **Liquid Glass** — system material on macOS 26.
- **Theming** — panel opacity, corner radius, background material, and a custom accent color.
- **Multi-monitor** — opens on the screen under the cursor.
- **Trackpad & haptics** — three-finger swipe to open the switcher or switch Spaces, with optional haptic and click feedback.
- **Hide from screen sharing** — keep the switcher out of screen recordings and shared screens. Needs macOS 14.6+.
- **Export & import** — back up and move your whole setup as a versioned `.cmdtab` file.
- **Configurable** — custom hotkey, size, scale, layout, grid columns, and reveal delay.

## Install

### Requirements

- macOS 13.0 (Ventura) or newer
- Accessibility permission

### Homebrew
```bash
brew install --cask bettercmdtab
```

### Download

Grab the latest signed `.dmg` from the [Releases page](https://github.com/rokartur/BetterCmdTab/releases), open it, drag `BetterCmdTab.app` to `/Applications`, and launch.

On first launch macOS will ask for **Accessibility** permission — this is required for the global ⌘+Tab event tap and for reading window lists via the Accessibility API. Grant it under `System Settings → Privacy & Security → Accessibility`.

### Build from source

If you prefer building it yourself from source, see [this section in CONTRIBUTING.md](CONTRIBUTING.md#Building) for instructions.

## Privacy

BetterCmdTab does not collect, transmit, or store any data. There is no telemetry, no crash reporting service, no analytics SDK, and no account. The only network requests it makes are to `api.github.com` and `github.com` when checking for updates, and only when you ask it to.

## Contributing

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, build / test instructions, and PR guidelines.

## License

GPL v3. See [LICENSE](LICENSE).

BetterCmdTab is licensed under the GNU General Public License v3.0. You are free to use, study, modify, and redistribute it — including for commercial purposes — but any distributed derivative work must also be released under GPL v3 with full source code. This keeps the project and any fork of it open, forever.

## Credits

Built by [@rokartur](https://github.com/rokartur). Inspired by [AltTab](https://alt-tab.app/), [Witch](https://manytricks.com/witch/), and [Contexts](https://contexts.co/).
