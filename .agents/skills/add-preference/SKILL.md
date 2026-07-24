---
name: add-preference
description: Contract for adding or changing a persisted setting in BetterCmdTab. Use when touching Preferences.swift, a settings pane, or any Switcher.* UserDefaults key.
---

# Add a preference

A setting is a multi-file contract keyed on one string. Follow every step that
applies; skipping one produces a setting that silently fails to persist,
export, or apply on the hot path.

## 1. Declare the key and property

In `BetterCmdTab/App/Preferences.swift`:

- Add the key to the `Keys` enum as `"Switcher.camelCaseName"`. The string is
  the contract — it is read by name in other files, exported to config files,
  and never renamed after shipping.
- Add a `@Published` property whose `didSet` persists to `UserDefaults`, and
  load it in `init` and in `reloadFromDefaults()` (settings import and
  config-file sync call this — a property missing there ignores imports).
  Copy the exact pattern of an adjacent property of the same type.
- Clamped ints get a `static let …Range: ClosedRange<Int>` next to the other
  range constants, and clamp on read.

**Complete when:** the property round-trips through `reloadFromDefaults()`.

## 2. Wire the hot path, if any

If the value is read while the switcher opens or cycles (`CatalogFilter`,
`SwitcherController`, `WindowEnumerator`, `Activator`, `HotkeyTap`,
`RecentlyClosedStore`), those consumers read the key string directly from
`UserDefaults.standard` off the main actor — never touch
`Preferences.shared` there. Match the existing direct-read sites in the file
you are editing.

**Complete when:** no hot-path code awaits the main actor to read the value.

## 3. Per-shortcut override, if applicable

If the setting should be overridable per shortcut (#74), extend
`ShortcutOverride` in `Preferences.swift`: add the optional field, its
`dictionary` encoding, the `init?(dictionary:)` decode, and the entry in
`knownKeys` (an omitted `knownKeys` entry makes the field bounce into
`passthrough` and never apply). Then resolve it where the other overrides
resolve into `CatalogFilter.Config` / reveal-time reads.

**Complete when:** the field survives a `dictionary` → `init?(dictionary:)`
round trip and is absent from `passthrough`.

## 4. Portability and config file — usually free

Export/import (`SettingsPortability.swift`) and
`~/.config/bettercmdtab/config.json` (`ConfigFile.swift`) pick up any
`Switcher.*` key automatically. Only act if the value is device-local state
(caches, recently-closed, machine-specific paths): add it to
`exportExcludedKeys` in `SettingsPortability.swift`.

## 5. UI and strings

Add the control to the matching pane view controller in
`BetterCmdTab/Settings/` (fragile or new behavior goes behind the
off-by-default Experimental pane). Register the control in
`SettingsCatalog.swift` if the pane search should find it. All labels use
`String(localized:)` — then follow the `localize-strings` skill for the
catalog entries.

## 6. Verify

New pure-logic behavior gets a Swift Testing test. Then run the suites the
contract touches:

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test \
  -only-testing:BetterCmdTabTests/PreferencesEnumTests \
  -only-testing:BetterCmdTabTests/SettingsPortabilityTests \
  -only-testing:BetterCmdTabTests/LocalizationCatalogTests
```

**Complete when:** those suites pass and the setting survives an
export → import round trip.
