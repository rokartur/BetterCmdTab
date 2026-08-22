import AppKit

/// The resolved appearance + reveal-time behavioral values for a single switcher
/// reveal (#74). Built once per trigger by overlaying the firing shortcut's
/// `ShortcutOverride` onto the global `Preferences`, then read by `SwitcherView`,
/// the item views, `SwitcherPanel`, and the reveal-time controller branches in
/// place of `Preferences.shared.*` — so a shortcut with an override shows its own
/// look without mutating any global state.
///
/// Holds an `NSColor`, so it is intentionally **not** `Sendable`: it is only ever
/// built and read on the main actor (the catalog hot path uses
/// `CatalogFilter.Config`, which is `Sendable`, instead).
struct EffectiveSettings {
    // Appearance.
    /// Selection highlight / jump-letter color, already resolved to a concrete
    /// color (#185). Not per-shortcut overridable — one switcher-wide answer.
    let selectionColor: NSColor
    /// Change-detection key for `selectionColor`, resolved once per reveal.
    /// `controlAccentColor` is the same object before and after the user changes
    /// the macOS accent, so the item views cannot compare colors by identity —
    /// and deriving a key per row would put a colorspace conversion and a string
    /// allocation on the ⌘Tab path for every row, every keystroke.
    let selectionColorKey: String
    /// `.transparent`: the selection plate drops its hue for the neutral
    /// luminance highlight instead. `selectionColor` still carries the accent,
    /// which letter hints and the launch/reopen glyphs keep using.
    let neutralSelection: Bool
    let layoutMode: SwitcherLayoutMode
    let panelScalePercent: Int
    let panelAppearance: PanelAppearance
    let fontScale: SwitcherFontScale
    let fontFace: SwitcherFontFace
    let gridMaxColumns: Int
    let gridSingleRow: Bool
    let listWidthPercent: Int
    let panelOpacity: Int
    let panelCornerRadius: Int
    let backdropMaterial: BackdropMaterial
    let showWindowTitleLabel: Bool
    let previewTitleAlignment: PreviewTitleAlignment
    let titleTruncationMode: TitleTruncationMode
    let boldSelectedLabel: Bool
    let showApplicationNames: Bool
    let showWindowStatusIcons: Bool
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
        let selection = resolvedSelectionColor
        return EffectiveSettings(
            selectionColor: selection,
            // The choice is part of the key because two of them resolve to the
            // same color: `.transparent` and `.system` both hand back the macOS
            // accent, and only the flag tells the plates apart.
            selectionColorKey: selectionColor.rawValue + (selection.hexString ?? selection.description),
            neutralSelection: selectionColor == .transparent,
            layoutMode: override.layoutMode ?? switcherLayoutMode,
            panelScalePercent: override.panelScalePercent.map(Self.clampPanelScalePercent) ?? panelScalePercent,
            panelAppearance: override.panelAppearance ?? panelAppearance,
            fontScale: override.fontScale ?? fontScale,
            fontFace: override.fontFace ?? fontFace,
            gridMaxColumns: override.gridMaxColumns ?? gridMaxColumns,
            // Not per-shortcut overridable: it is one global answer to "does the
            // grid wrap", so `ShortcutOverride` carries no field for it.
            gridSingleRow: gridSingleRow,
            listWidthPercent: override.listWidthPercent ?? listWidthPercent,
            panelOpacity: override.panelOpacity ?? panelOpacity,
            panelCornerRadius: override.panelCornerRadius ?? panelCornerRadius,
            backdropMaterial: override.backdropMaterial ?? backdropMaterial,
            showWindowTitleLabel: override.showWindowTitleLabel ?? showWindowTitleLabel,
            previewTitleAlignment: override.previewTitleAlignment ?? previewTitleAlignment,
            titleTruncationMode: override.titleTruncationMode ?? titleTruncationMode,
            boldSelectedLabel: override.boldSelectedLabel ?? boldSelectedLabel,
            showApplicationNames: override.showApplicationNames ?? showApplicationNames,
            showWindowStatusIcons: override.showWindowStatusIcons ?? showWindowStatusIcons,
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
