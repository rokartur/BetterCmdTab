import AppKit

/// The resolved appearance + reveal-time behavioral values for a single switcher
/// reveal (#74). Built once per trigger by overlaying the firing shortcut's
/// `ShortcutOverride` onto the global `Preferences`, then read by `SwitcherView`,
/// the item views, `SwitcherPanel`, and the reveal-time controller branches in
/// place of `Preferences.shared.*` — so a shortcut with an override shows its own
/// look without mutating any global state.
///
/// Only ever built and read on the main actor (the catalog hot path uses
/// `CatalogFilter.Config`, which is `Sendable`, instead).
struct EffectiveSettings {
    // Appearance. The selection accent isn't here: it always follows the
    // user's macOS accent (`NSColor.controlAccentColor`), read at draw time.
    let layoutMode: SwitcherLayoutMode
    let panelSize: PanelSize
    let fontScale: SwitcherFontScale
    let fontFace: SwitcherFontFace
    let gridMaxColumns: Int
    let panelOpacity: Int
    let panelCornerRadius: Int
    let backdropMaterial: BackdropMaterial
    let showWindowTitleLabel: Bool
    let previewTitleAlignment: PreviewTitleAlignment
    let titleTruncationMode: TitleTruncationMode
    let boldSelectedLabel: Bool
    let showApplicationNames: Bool
    let showUnreadBadges: Bool
    let letterHintsEnabled: Bool
    // Behavioral values applied on the main-actor reveal path (the rest ride
    // `CatalogFilter.Config` into the off-main catalog filter).
    let applicationsOnly: Bool
    let expandBrowserTabsAsWindows: Bool
    let sortOrder: SwitcherSortOrder
    let stayOpenOnRelease: Bool
    let stayOpenOnQuickTap: Bool

    /// The all-global snapshot (no override). Cheap; reads `Preferences.shared`.
    @MainActor static var defaults: EffectiveSettings {
        Preferences.shared.effectiveSettings(for: ShortcutOverride())
    }
}

extension Preferences {
    /// Resolve every overridable value to a concrete `EffectiveSettings`,
    /// preferring the override's field when set and otherwise the global
    /// preference.
    func effectiveSettings(for override: ShortcutOverride) -> EffectiveSettings {
        EffectiveSettings(
            layoutMode: override.layoutMode ?? switcherLayoutMode,
            panelSize: override.panelSize ?? panelSize,
            fontScale: override.fontScale ?? fontScale,
            fontFace: override.fontFace ?? fontFace,
            gridMaxColumns: override.gridMaxColumns ?? gridMaxColumns,
            panelOpacity: override.panelOpacity ?? panelOpacity,
            panelCornerRadius: override.panelCornerRadius ?? panelCornerRadius,
            backdropMaterial: override.backdropMaterial ?? backdropMaterial,
            showWindowTitleLabel: override.showWindowTitleLabel ?? showWindowTitleLabel,
            previewTitleAlignment: override.previewTitleAlignment ?? previewTitleAlignment,
            titleTruncationMode: override.titleTruncationMode ?? titleTruncationMode,
            boldSelectedLabel: override.boldSelectedLabel ?? boldSelectedLabel,
            showApplicationNames: override.showApplicationNames ?? showApplicationNames,
            showUnreadBadges: override.showUnreadBadges ?? showUnreadBadges,
            letterHintsEnabled: override.letterHintsEnabled ?? letterHintsEnabled,
            applicationsOnly: override.applicationsOnly ?? applicationsOnly,
            expandBrowserTabsAsWindows: override.expandBrowserTabsAsWindows ?? expandBrowserTabsAsWindows,
            sortOrder: override.sortOrder ?? sortOrder,
            stayOpenOnRelease: override.stayOpenOnRelease ?? stayOpenOnRelease,
            stayOpenOnQuickTap: override.stayOpenOnQuickTap ?? stayOpenOnQuickTap
        )
    }
}
