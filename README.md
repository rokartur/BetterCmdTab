<div align="center">

<img src="https://github.com/user-attachments/assets/3e4bbb67-ef7d-4619-8068-1458d8460331" width="160" height="160" alt="BetterCmdTab" />

# BetterCmdTab

**The ⌘+Tab macOS deserves.**

Fast · Native · Liquid Glass · Zero telemetry · Free forever

[![image](https://img.shields.io/badge/Download_Latest_Release-F5F5F4?style=for-the-badge&logo=apple&logoColor=black)](https://github.com/rokartur/BetterCmdTab/releases/latest)

<p>
  <a href="https://github.com/rokartur/BetterCmdTab/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/rokartur/BetterCmdTab?include_prereleases&style=for-the-badge&label=download&color=white&logo=apple&logoColor=white"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13.0+-000?style=for-the-badge&logo=apple&logoColor=white&color=white">
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

<img src="https://github.com/user-attachments/assets/f8315d7a-b4cb-4c39-9be4-1abde57629e8" width="100%" alt="BetterCmdTab switcher on macOS 26 with Liquid Glass" />

</div>

## Why

macOS's built-in ⌘+Tab switches apps, not windows. Third-party alternatives either cost money (Witch, Contexts) or feel heavy and have not adopted Liquid Glass. BetterCmdTab is a single menu-bar agent that boots in milliseconds, draws with the system Liquid Glass material on macOS 26, and ships with no subscription, no license key, and no analytics.

## Features

- **Two layouts** — classic vertical list, or a grid of app icons with spatial arrow-key navigation.
- **Window-level switching** — `` ⌘+ ` `` cycles the windows of the frontmost app. Works on every app.
- **Letter-prefix jump** — start typing the first letters of an app name to reorder the list and jump to the match.
- **Quick actions on the highlighted row** — quit, close window, minimize, hide, all without leaving the switcher.
- **Liquid Glass backdrop on macOS 26**, NSVisualEffectView fallback below.
- **Multi-monitor aware** — opens on the screen with the cursor; repositions when displays connect, disconnect, or change resolution.
- **Shift+tap** to step backwards without holding Tab.
- **Menu bar agent** — no dock icon, no main window, no Electron.

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

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, build / test instructions, and PR guidelines.

## License

GPL v3. See [LICENSE](LICENSE).

BetterCmdTab is licensed under the GNU General Public License v3.0. You are free to use, study, modify, and redistribute it — including for commercial purposes — but any distributed derivative work must also be released under GPL v3 with full source code. This keeps the project and any fork of it open, forever.

## Credits

Built by [@rokartur](https://github.com/rokartur). Inspired by [AltTab](https://alt-tab.app/), [Witch](https://manytricks.com/witch/), and [Contexts](https://contexts.co/).
