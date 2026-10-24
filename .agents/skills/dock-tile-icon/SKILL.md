---
name: dock-tile-icon
description: Make the switcher show an app's Dock icon when it differs from the bundle icon. Use when a switcher tile's icon does not match the Dock, or when touching Catalog/DockTileIcon.swift.
---

# Dock tile icon

The system ⌘Tab runs inside the Dock process and reads the tile image directly
(`-[ASAppSwitcher show:]` calls `-[Tile getImage:glassCompositingFilter:]`). The
Dock exposes no call that returns a tile image to another process: its
`DockExtraServer` and `CoreDock*` entry points only set images. So each app
whose Dock icon differs gets a hand-written entry in
`BetterCmdTab/Catalog/DockTileIcon.swift` that rebuilds the same icon from the
app's own bundle and preferences.

## 1. Classify the mismatch

Compare three icons: the Dock tile, the system ⌘Tab (quit BetterCmdTab, then
press ⌘Tab) and the BetterCmdTab tile. Then pick the class:

- **Finder custom icon** (Get Info, `NSWorkspace.setIcon`): `NSRunningApplication.icon`
  already returns it. If the tile still differs, it is a stale `IconCache`
  entry, not a `DockTileIcon` case.
- **Dock-only static icon**: the app sets `NSApp.applicationIconImage` or ships
  an `NSDockTilePlugIn` that picks one of a few icons from a preference or the
  appearance. This is the only class `DockTileIcon` handles.
- **Live content** (Calendar date, Clock hands, progress bars, badges): drawn
  every minute or on events. Out of scope: report it and stop.

**Complete when:** the app is in exactly one class, with the evidence named.

## 2. Find the icon source

For a Dock-only static icon, find three facts in the app bundle:

1. **The images**: `plutil -extract NSDockTilePlugIn raw <app>/Contents/Info.plist`
   names the plugin; `assetutil --info <app>/Contents/Resources/Assets.car`
   lists the alternate icon names (cmux: `AppIconDark`, `AppIconLight`).
2. **The selector**: the defaults key and values that pick the image.
   `defaults read <bundle id>` while flipping the in-app setting shows it; the
   app's source or `strings` on the plugin binary confirms the values.
3. **The change signal**: a distributed notification the app posts when the
   icon changes (cmux: `com.cmuxterm.appIconDidChange`). Search the source or
   `strings` for a reverse-DNS name. No signal means the system appearance
   notification is the only eviction trigger, so say so in the report.

Closed-source app: decompile the plugin with the `rea` CLI (Hopper at
`/Applications/Hopper Disassembler.app`, set `HOPPER_LAUNCHER_PATH` to its
`Contents/MacOS/hopper`) and read the method that calls `setContentView:` or
`setApplicationIconImage:`.

**Complete when:** each of the three facts has a concrete value, or is
confirmed absent.

## 3. Add the entry

In `DockTileIcon.swift`, match on the bundle identifier, read the selector
with `CFPreferencesAppSynchronize` then `CFPreferencesCopyAppValue` (the app's
domain, not ours), and load the image with `Bundle(url:).image(forResource:)`.
Return nil for anything unmatched so `IconCache` falls back to the bundle icon.
Add the change notification to `observeChanges()` and evict that bundle
identifier.

Keep it on the cache-miss path only: `IconCache` calls `DockTileIcon` before
caching, so the ⌘Tab hot path never reads a bundle. Match the stable bundle
identifier only; nightly and beta builds show their bundle icon.

**Complete when:** `xc build` passes.

## 4. Verify

Run the Debug build, open the switcher with `macui chord 1500 48`, and
compare the tile to the Dock in every selector value and in light and dark
appearance. Flip the setting while BetterCmdTab runs: the next ⌘Tab shows the
new icon without a relaunch. Restore the app's original setting afterwards,
and quit with `osascript -e 'quit app "BetterCmdTab Debug"'`.

**Complete when:** a screenshot per selector value matches the Dock.
