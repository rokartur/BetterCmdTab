# Architecture

How the pieces under `BetterCmdTab/` fit together and the constraints a directory listing does
not show. The folder names (`Input/`, `Catalog/`, `Switcher/`, `Windows/`, `System/`,
`Settings/`) say what each file does; this file says what crosses between them.

## Boot

A menu-bar (`.accessory`) app. `App/AppDelegate.swift` wires everything at launch and owns the
single `SwitcherController`, but the controller boots only after Accessibility is trusted:
`AccessibilityWaiter` polls `AXIsProcessTrusted()` and then calls `bootController()`. The
`Better*` SPM packages (`BetterSettings`, `BetterUpdater`, `BetterShortcuts`) are first-party,
under `rokartur/*`.

## The ⌘Tab hot path

Chord in `Input/`, apps and windows from `Catalog/`, state in `Switcher/`, the chosen item acted
on in `Windows/`:

- `Input/HotkeyTap` is a CGEvent tap on its **own thread**; it detects the chord and
  suppresses the native switcher. The tap goes deaf under **Secure Event Input** (a focused
  password field), so `Input/CarbonHotkeyTrigger` (`RegisterEventHotKey`) is the survivor
  trigger that still opens the panel there.
- `Catalog/AppCatalog` enumerates apps and windows through the Accessibility API.
  `Catalog/AppCatalogCache` keeps an incremental cache of that result, fed by AX observers and
  MRU bumps, so the panel opens from cache instead of waiting on AX.
- `Switcher/SwitcherController` is the state machine (selection, letter-jump, fuzzy search,
  tab drill-in). `Switcher/SwitcherPanel` is a non-activating panel, so the frontmost app keeps
  focus while the switcher is up.
- `Windows/Activator` performs activate, raise, close, hide and quit; `MRUTracker` and
  `WindowMRUTracker` order apps and windows by recency.

`System/PrivateAPIs.swift` holds every private CGS/SkyLight call in one file so review can
see all of it at once; new private glue goes there.

## Preferences and persistence

`App/Preferences.swift` is the `@MainActor` singleton (`Preferences.shared`) whose
`@Published` properties persist to `UserDefaults` under `Switcher.*` keys. Hot-path consumers
(`CatalogFilter`, `SwitcherController`) read a few of those keys (sort order, app exceptions,
expand-tabs) **straight off `UserDefaults` off the main actor**, by key string, so the string
is a shipped contract. The `add-preference` skill is the procedure for adding or changing one.

`App/SettingsPortability.swift` exports and imports the whole `Switcher.*` namespace as flat,
prefix-free JSON. Import also accepts the legacy `.cmdtab` envelope (`schemaVersion`, UTI
`pro.bettercmdtab.settings`), is partial (absent keys keep their current value), and calls
`reloadFromDefaults()` so live subscribers refresh.

`App/ConfigFile.swift` two-way-syncs the same flat format with
`~/.config/bettercmdtab/config.json` (`$XDG_CONFIG_HOME` honored) when that file exists: an
event-driven watcher plus debounced write-back, dormant when the file is absent (#117). It also
writes a sidecar `schema.json` (the config's `$schema` target) generated from the live
snapshot, types only and open-ended, so a new preference needs no schema edit.
