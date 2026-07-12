import AppKit
import Foundation
import Testing
@testable import BetterCmdTab

/// Pure-logic tests for per-shortcut overrides (#74): the override value type,
/// its plist round-trip, the `CatalogFilter.Config` overlay, the storage
/// encode/decode, and the `EffectiveSettings` resolution. No WindowServer/AX, so
/// these run in the headless unit suite.
@MainActor
@Suite("Shortcut overrides")
struct ShortcutOverrideTests {

    // MARK: - SwitchTarget storage contract

    @Test("storageKey ↔ init round-trips for every target")
    func targetRoundTrip() {
        #expect(SwitchTarget.switchApps.storageKey == "switchApps")
        #expect(SwitchTarget.switchWindows.storageKey == "switchWindows")
        #expect(SwitchTarget.scoped(0).storageKey == "scoped.0")
        #expect(SwitchTarget(storageKey: "switchApps") == .switchApps)
        #expect(SwitchTarget(storageKey: "switchWindows") == .switchWindows)
        #expect(SwitchTarget(storageKey: "scoped.1") == .scoped(1))
        // The scoped list is dynamic, so any non-negative id is valid (not slot-bounded).
        #expect(SwitchTarget(storageKey: "scoped.999") == .scoped(999))
    }

    @Test("malformed scoped keys are rejected")
    func targetRejectsBadKeys() {
        #expect(SwitchTarget(storageKey: "scoped.-1") == nil)
        #expect(SwitchTarget(storageKey: "scoped.x") == nil)
        #expect(SwitchTarget(storageKey: "scoped.") == nil)
        #expect(SwitchTarget(storageKey: "bogus") == nil)
    }

    // MARK: - ScopedShortcut (dynamic list)

    @Test("ScopedShortcut dictionary round-trips")
    func scopedShortcutRoundTrip() {
        let entry = ScopedShortcut(id: 7, scope: .minimizedOnly, shortcutName: "scopedSwitch.7")
        let parsed = ScopedShortcut(dictionary: entry.dictionary)
        #expect(parsed == entry)
    }

    @Test("ScopedShortcut rejects malformed dictionaries")
    func scopedShortcutRejectsBad() {
        #expect(ScopedShortcut(dictionary: ["scope": "minimizedOnly", "name": "x"]) == nil) // no id
        #expect(ScopedShortcut(dictionary: ["id": "-1", "name": "x"]) == nil)               // negative id
        #expect(ScopedShortcut(dictionary: ["id": "1", "name": ""]) == nil)                 // empty name
        // Unknown scope falls back to the default rather than dropping the entry.
        #expect(ScopedShortcut(dictionary: ["id": "1", "name": "x", "scope": "bogus"])?.scope == .allAppsAllSpaces)
    }

    @Test("decodeScopedShortcuts drops malformed entries")
    func decodeScopedList() {
        let raw: [[String: String]] = [
            ["id": "0", "scope": "allAppsAllSpaces", "name": "scopedSwitch1"],
            ["scope": "minimizedOnly", "name": "x"], // no id → dropped
            ["id": "5", "scope": "currentAppWindows", "name": "scopedSwitch.5"],
        ]
        let decoded = Preferences.decodeScopedShortcuts(raw)
        #expect(decoded.count == 2)
        #expect(decoded.map(\.id) == [0, 5])
        #expect(decoded[1].scope == .currentAppWindows)
    }

    // MARK: - SpaceScopeOverride

    @Test("space-scope override maps to the concrete SpaceScope")
    func spaceScopeMapping() {
        #expect(SpaceScopeOverride.inherit.resolvedScope == nil)
        #expect(SpaceScopeOverride.currentSpace.resolvedScope == .currentSpace)
        #expect(SpaceScopeOverride.allSpaces.resolvedScope == .allSpaces)
        #expect(SpaceScopeOverride.visibleSpaces.resolvedScope == .visibleSpaces)
    }

    // MARK: - ShortcutOverride dictionary round-trip

    @Test("empty override is isEmpty and emits an empty dictionary")
    func emptyOverride() {
        let ov = ShortcutOverride()
        #expect(ov.isEmpty)
        #expect(ov.dictionary.isEmpty)
    }

    @Test("dictionary round-trips a fully-populated override")
    func dictionaryRoundTrip() {
        var ov = ShortcutOverride()
        ov.spaceScope = .allSpaces
        ov.showMinimized = false
        ov.showHidden = true
        ov.showWindowless = false
        ov.sortOrder = .alphabetical
        ov.applicationsOnly = true
        ov.expandBrowserTabsAsWindows = false
        ov.stayOpenOnRelease = true
        ov.stayOpenOnQuickTap = false
        ov.layoutMode = .list
        ov.panelScalePercent = 73
        ov.panelAppearance = .dark
        ov.fontScale = .small
        ov.fontFace = .monospaced
        ov.gridMaxColumns = 7
        ov.panelOpacity = 80
        ov.panelCornerRadius = 12
        ov.backdropMaterial = .sidebar
        ov.showWindowTitleLabel = false
        ov.previewTitleAlignment = .leading
        ov.titleTruncationMode = .middle
        ov.boldSelectedLabel = false
        ov.showApplicationNames = true
        ov.showUnreadBadges = false
        ov.letterHintsEnabled = true
        #expect(!ov.isEmpty)
        #expect(ShortcutOverride(dictionary: ov.dictionary) == ov)
    }

    @Test("only set fields are emitted; absent keys read back as inherit")
    func dictionaryOmitsUnsetFields() {
        var ov = ShortcutOverride()
        ov.spaceScope = .currentSpace
        let dict = ov.dictionary
        #expect(dict == ["spaceScope": "currentSpace"])
        let parsed = ShortcutOverride(dictionary: dict)
        #expect(parsed?.spaceScope == .currentSpace)
        #expect(parsed?.sortOrder == nil)
        #expect(parsed?.applicationsOnly == nil)
    }

    @Test("legacy panel preset migrates to a clamped continuous override")
    func legacyPanelScaleOverride() {
        let legacy = ShortcutOverride(dictionary: ["panelSize": "standard"])
        #expect(legacy?.panelScalePercent == 120)
        #expect(legacy?.dictionary["panelScalePercent"] == "120")
        #expect(legacy?.dictionary["panelSize"] == nil)

        let corrupt = ShortcutOverride(dictionary: ["panelScalePercent": "999"])
        #expect(corrupt?.panelScalePercent == 150)
    }

    @Test("unknown keys survive the round-trip instead of being stripped")
    func dictionaryPassesThroughUnknownKeys() {
        let parsed = ShortcutOverride(dictionary: ["spaceScope": "allSpaces", "futureField": "42"])
        #expect(parsed?.spaceScope == .allSpaces)
        #expect(parsed?.isEmpty == false)
        // The unknown key rides along in `passthrough` and is re-emitted, so
        // re-saving on this build doesn't destroy another build's data.
        #expect(parsed?.passthrough == ["futureField": "42"])
        #expect(parsed?.dictionary["futureField"] == "42")
        // An entry whose only content is unknown keys (e.g. a retired accent
        // override) is not "empty" — it must survive storage, not be dropped.
        let foreignOnly = ShortcutOverride(dictionary: ["accentChoice": "green"])
        #expect(foreignOnly?.isEmpty == false)
        #expect(foreignOnly?.dictionary == ["accentChoice": "green"])
        // The "target" envelope key stamped by the codec is not passthrough.
        let stamped = ShortcutOverride(dictionary: ["target": "switchApps", "spaceScope": "allSpaces"])
        #expect(stamped?.passthrough.isEmpty == true)
    }

    // MARK: - CatalogFilter.overlay

    private func baseConfig(
        showMinimized: Bool = true,
        spaceScope: SpaceScope = .allSpaces,
        sortOrder: SwitcherSortOrder = .mru
    ) -> CatalogFilter.Config {
        CatalogFilter.Config(
            hideModes: ["com.example.app": .always],
            pinned: ["com.example.pin"],
            showMinimized: showMinimized,
            showHidden: true,
            showWindowless: true,
            spaceScope: spaceScope,
            sortOrder: sortOrder
        )
    }

    @Test("empty overlay leaves the config untouched")
    func overlayEmpty() {
        let base = baseConfig()
        let result = CatalogFilter.overlay(base, ShortcutOverride())
        #expect(result.spaceScope == base.spaceScope)
        #expect(result.showMinimized == base.showMinimized)
        #expect(result.sortOrder == base.sortOrder)
        #expect(result.hideModes == base.hideModes)
        #expect(result.pinned == base.pinned)
    }

    @Test("space-scope override forces the scope in any direction")
    func overlaySpaceScope() {
        var toCurrent = ShortcutOverride(); toCurrent.spaceScope = .currentSpace
        #expect(CatalogFilter.overlay(baseConfig(spaceScope: .allSpaces), toCurrent).spaceScope == .currentSpace)
        var toAll = ShortcutOverride(); toAll.spaceScope = .allSpaces
        #expect(CatalogFilter.overlay(baseConfig(spaceScope: .currentSpace), toAll).spaceScope == .allSpaces)
        var toVisible = ShortcutOverride(); toVisible.spaceScope = .visibleSpaces
        #expect(CatalogFilter.overlay(baseConfig(spaceScope: .allSpaces), toVisible).spaceScope == .visibleSpaces)
    }

    @Test("behavioral fields override when set and inherit when nil")
    func overlayFields() {
        var ov = ShortcutOverride()
        ov.showMinimized = false
        ov.sortOrder = .alphabetical
        let result = CatalogFilter.overlay(baseConfig(showMinimized: true, sortOrder: .mru), ov)
        #expect(result.showMinimized == false)
        #expect(result.sortOrder == .alphabetical)
        // Unset fields and non-overridable fields pass through unchanged.
        #expect(result.showHidden == true)
        #expect(result.hideModes.count == 1)
        #expect(result.pinned == ["com.example.pin"])
    }

    @Test("overlaying an empty override preserves an identity config")
    func overlayKeepsIdentity() {
        let identity = CatalogFilter.Config(hideModes: [:], pinned: [], showMinimized: true, showHidden: true, showWindowless: true, spaceScope: .allSpaces, sortOrder: .mru)
        #expect(identity.isIdentity)
        #expect(CatalogFilter.overlay(identity, ShortcutOverride()).isIdentity)
    }

    // MARK: - Preferences encode/decode

    @Test("encode drops empty overrides and stamps the target key")
    func encodeDropsEmpty() {
        var populated = ShortcutOverride(); populated.spaceScope = .currentSpace
        let map: [String: ShortcutOverride] = [
            SwitchTarget.switchApps.storageKey: populated,
            SwitchTarget.switchWindows.storageKey: ShortcutOverride(), // empty → dropped
        ]
        let encoded = Preferences.encodeShortcutOverrides(map)
        #expect(encoded.count == 1)
        #expect(encoded[0]["target"] == "switchApps")
        #expect(encoded[0]["spaceScope"] == "currentSpace")
    }

    @Test("encode output is deterministic (sorted by target)")
    func encodeDeterministic() {
        var a = ShortcutOverride(); a.spaceScope = .currentSpace
        var b = ShortcutOverride(); b.spaceScope = .allSpaces
        let map: [String: ShortcutOverride] = [
            SwitchTarget.switchWindows.storageKey: b,
            SwitchTarget.switchApps.storageKey: a,
        ]
        let encoded = Preferences.encodeShortcutOverrides(map)
        #expect(encoded.map { $0["target"] } == ["switchApps", "switchWindows"])
    }

    @Test("decode round-trips and rejects unknown targets")
    func decodeRoundTrip() {
        var ov = ShortcutOverride(); ov.sortOrder = .launchOrder; ov.panelOpacity = 55
        let map = [SwitchTarget.scoped(2).storageKey: ov]
        let decoded = Preferences.decodeShortcutOverrides(Preferences.encodeShortcutOverrides(map))
        #expect(decoded == map)
        // An entry with an unknown target is dropped.
        let withBad = Preferences.decodeShortcutOverrides([["target": "bogus", "spaceScope": "allSpaces"]])
        #expect(withBad.isEmpty)
        // A nil/empty raw decodes to an empty map (no crash).
        #expect(Preferences.decodeShortcutOverrides(nil).isEmpty)
    }

    @Test("decode re-keys a non-canonical target to its canonical form")
    func decodeCanonicalizesKey() {
        // A hand-edited/corrupt import can carry a valid-but-non-canonical key:
        // "scoped.007" parses to .scoped(7). It must be stored under the canonical
        // "scoped.7" so override(for:) / setOverride can find and clear it — keying
        // by the raw string would leave it silently inert and unclearable.
        let decoded = Preferences.decodeShortcutOverrides([["target": "scoped.007", "spaceScope": "currentSpace"]])
        #expect(decoded.count == 1)
        #expect(decoded[SwitchTarget.scoped(7).storageKey]?.spaceScope == .currentSpace)
        #expect(decoded["scoped.007"] == nil)
    }

    // MARK: - EffectiveSettings resolution

    @Test("empty override inherits every global value")
    func effectiveInheritsGlobals() {
        let prefs = Preferences.shared
        let eff = prefs.effectiveSettings(for: ShortcutOverride())
        #expect(eff.layoutMode == prefs.switcherLayoutMode)
        #expect(eff.panelScalePercent == prefs.panelScalePercent)
        #expect(eff.panelAppearance == prefs.panelAppearance)
        #expect(eff.applicationsOnly == prefs.applicationsOnly)
        #expect(eff.sortOrder == prefs.sortOrder)
        #expect(eff.showUnreadBadges == prefs.showUnreadBadges)
    }

    @Test("a one-field override changes only that field")
    func effectiveOverridesOneField() {
        let prefs = Preferences.shared
        var ov = ShortcutOverride()
        // Pick a layout that differs from the current global so the assertion is real.
        let target: SwitcherLayoutMode = prefs.switcherLayoutMode == .list ? .gridView : .list
        ov.layoutMode = target
        let eff = prefs.effectiveSettings(for: ov)
        #expect(eff.layoutMode == target)
        // Everything else still tracks the global.
        #expect(eff.panelScalePercent == prefs.panelScalePercent)
        #expect(eff.panelAppearance == prefs.panelAppearance)
        #expect(eff.sortOrder == prefs.sortOrder)
    }

    @Test("panel scale and theme resolve profile overrides over globals")
    func effectivePanelAppearanceOverride() {
        let prefs = Preferences.shared
        var ov = ShortcutOverride()
        ov.panelScalePercent = prefs.panelScalePercent == 50 ? 51 : 50
        ov.panelAppearance = prefs.panelAppearance == .dark ? .light : .dark
        let eff = prefs.effectiveSettings(for: ov)
        #expect(eff.panelScalePercent == ov.panelScalePercent)
        #expect(eff.panelAppearance == ov.panelAppearance)
    }

    @Test("stay-open resolves the override over the global (#77)")
    func effectiveStayOpenOverride() {
        let prefs = Preferences.shared
        var ov = ShortcutOverride()
        // Force the opposite of the current global so the assertion is real.
        let target = !prefs.stayOpenOnRelease
        ov.stayOpenOnRelease = target
        #expect(prefs.effectiveSettings(for: ov).stayOpenOnRelease == target)
        // Unset inherits the global.
        #expect(prefs.effectiveSettings(for: ShortcutOverride()).stayOpenOnRelease == prefs.stayOpenOnRelease)
    }

    @Test("quick-tap stay-open resolves the override over the global (#91)")
    func effectiveQuickTapOverride() {
        let prefs = Preferences.shared
        var ov = ShortcutOverride()
        // Force the opposite of the current global so the assertion is real.
        let target = !prefs.stayOpenOnQuickTap
        ov.stayOpenOnQuickTap = target
        #expect(prefs.effectiveSettings(for: ov).stayOpenOnQuickTap == target)
        // Unset inherits the global.
        #expect(prefs.effectiveSettings(for: ShortcutOverride()).stayOpenOnQuickTap == prefs.stayOpenOnQuickTap)
    }

    @Test("text size and font face resolve the override over the global (#62)")
    func effectiveFontOverride() {
        let prefs = Preferences.shared
        var ov = ShortcutOverride()
        // Force values that differ from the current globals so the assertions are real.
        let scaleTarget: SwitcherFontScale = prefs.fontScale == .large ? .small : .large
        let faceTarget: SwitcherFontFace = prefs.fontFace == .monospaced ? .rounded : .monospaced
        ov.fontScale = scaleTarget
        ov.fontFace = faceTarget
        let eff = prefs.effectiveSettings(for: ov)
        #expect(eff.fontScale == scaleTarget)
        #expect(eff.fontFace == faceTarget)
        // Unset inherits the globals.
        let inherited = prefs.effectiveSettings(for: ShortcutOverride())
        #expect(inherited.fontScale == prefs.fontScale)
        #expect(inherited.fontFace == prefs.fontFace)
    }

    @Test("title truncation resolves the override over the global (#90)")
    func effectiveTitleTruncationOverride() {
        let prefs = Preferences.shared
        var ov = ShortcutOverride()
        // Pick a mode that differs from the current global so the assertion is real.
        let target: TitleTruncationMode = prefs.titleTruncationMode == .head ? .middle : .head
        ov.titleTruncationMode = target
        #expect(prefs.effectiveSettings(for: ov).titleTruncationMode == target)
        // Unset inherits the global.
        #expect(prefs.effectiveSettings(for: ShortcutOverride()).titleTruncationMode == prefs.titleTruncationMode)
    }
}
