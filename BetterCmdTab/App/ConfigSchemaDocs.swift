import Foundation

/// The allowed values of a setting, each paired with the label the Settings UI
/// shows for it, so an editor's completion list explains a value instead of
/// only listing its raw form. The labels come straight from the enum's
/// `displayName`, so they can't drift from the app — and they are localized,
/// which means a schema generated on a Polish Mac completes in Polish.
struct ConfigValues: Sendable, ExpressibleByArrayLiteral {
    let raw: [String]
    let labels: [String]?

    /// Every case of a string-backed enum, labelled by `label` (always
    /// `\.displayName`, kept as a parameter because the enums share no protocol).
    init<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ label: (T) -> String)
    where T.RawValue == String {
        raw = T.allCases.map(\.rawValue)
        labels = T.allCases.map(label)
    }

    /// Values that name themselves — system sound files, retired presets, the
    /// `"true"`/`"false"` form of a stringified bool.
    init(arrayLiteral elements: String...) {
        raw = elements
        labels = nil
    }

    /// Same values, re-labelled or not, for a stringified override field.
    init(raw: [String], labels: [String]?) {
        self.raw = raw
        self.labels = labels
    }

    /// `enum` is the validation; `enumDescriptions` is the completion text.
    /// The latter is an editor extension (VS Code, JetBrains) that plain
    /// validators ignore, which is why the values also stand on their own.
    var fragment: [String: Any] {
        guard let labels else { return ["enum": raw] }
        return ["enum": raw, "enumDescriptions": labels]
    }
}

/// Element schema of an array setting — a scalar (optionally constrained to a
/// set of values) or an object with typed properties. The stored dictionaries
/// (`appExceptions`, `scopedShortcutList`, `shortcutOverrides`) are plists of
/// `[String: String]`, so their *values* are the string forms of the types the
/// app parses back out — that's what these describe.
struct ConfigItemSchema: Sendable {
    let type: String
    let values: ConfigValues?
    /// Shape of a scalar element that isn't a closed set of values — the
    /// bundle-ID arrays.
    let pattern: String?
    let properties: [String: ConfigSettingDoc]
    let required: [String]
    /// `additionalProperties` for object elements. Open only where unknown keys
    /// are deliberately preserved (`ShortcutOverride.passthrough`).
    let open: Bool

    init(
        _ type: String,
        values: ConfigValues? = nil,
        pattern: String? = nil,
        properties: [String: ConfigSettingDoc] = [:],
        required: [String] = [],
        open: Bool = false
    ) {
        self.type = type
        self.values = values
        self.pattern = pattern
        self.properties = properties
        self.required = required
        self.open = open
    }

    var fragment: [String: Any] {
        var out: [String: Any] = ["type": type]
        if let values { out.merge(values.fragment) { a, _ in a } }
        if let pattern { out["pattern"] = pattern }
        guard !properties.isEmpty else { return out }
        out["properties"] = properties.mapValues(\.fragment)
        out["additionalProperties"] = open
        if !required.isEmpty { out["required"] = required.sorted() }
        return out
    }
}

/// One documented key in the generated config schema.
struct ConfigSettingDoc: Sendable {
    let type: String
    let text: String
    /// Allowed values, read from the live `CaseIterable` enum so the schema
    /// can't drift from what the app accepts.
    let values: ConfigValues?
    /// Accepted numeric span, read from the matching `Preferences.*Range` clamp.
    let range: ClosedRange<Int>?
    /// Regex for values the app persists as strings but parses as something
    /// else (the plist dictionaries store every field as a string).
    let pattern: String?
    /// Fixed-length arrays — the app pads/truncates to exactly this many slots.
    let count: Int?
    /// Element schema for `type == "array"`.
    let item: ConfigItemSchema?

    init(
        _ type: String,
        _ text: String,
        values: ConfigValues? = nil,
        range: ClosedRange<Int>? = nil,
        pattern: String? = nil,
        count: Int? = nil,
        item: ConfigItemSchema? = nil
    ) {
        self.type = type
        self.text = text
        self.values = values
        self.range = range
        self.pattern = pattern
        self.count = count
        self.item = item
    }

    /// The key's JSON Schema fragment.
    var fragment: [String: Any] {
        var out: [String: Any] = ["type": type, "description": text]
        if let values { out.merge(values.fragment) { a, _ in a } }
        if let range {
            out["minimum"] = range.lowerBound
            out["maximum"] = range.upperBound
        }
        if let pattern { out["pattern"] = pattern }
        if let count {
            out["minItems"] = count
            out["maxItems"] = count
        }
        if let item { out["items"] = item.fragment }
        return out
    }
}

/// Descriptions, allowed values, ranges and element shapes for the sidecar
/// `schema.json` (#117). A types-only schema left editors with nothing to
/// complete or explain — hovering a key showed nothing and `"layoutMode":
/// "grrid"` drew no warning. Keys absent from this table still get their type
/// from the live snapshot, so a preference added later is undocumented, never
/// invalid.
///
/// Descriptions are English on purpose: this is a machine-readable sidecar
/// whose bytes should stay stable, not UI text. The per-value labels are the
/// exception — they are the Settings UI's own `displayName`, localized, because
/// re-typing 60 enum captions here only buys a second copy to keep in sync.
enum ConfigSchemaDocs {
    /// Built once per process (`static let`), which is also what keeps the one
    /// disk read in here — the system-sound list — off the repeated schema
    /// write-back path.
    static let byKey: [String: ConfigSettingDoc] = {
        var docs = base
        docs["shortcutOverrides"] = ConfigSettingDoc(
            "array",
            "Per-shortcut overrides of the global settings. Each entry names its shortcut in \"target\"; every other field is optional and inherits the global value when absent.",
            item: ConfigItemSchema(
                "object",
                properties: overrideProperties(from: base),
                required: ["target"],
                // Unknown keys are preserved verbatim (ShortcutOverride.passthrough)
                // so a downgrade can't strip a newer build's override.
                open: true
            )
        )
        return docs
    }()

    // MARK: - Per-shortcut overrides

    /// Override fields whose name differs from the global key they mirror.
    private static let overrideFieldSources = [
        "showMinimized": "showMinimizedWindows",
        "showHidden": "showHiddenApps",
        "showWindowless": "showWindowlessApps",
    ]

    /// Every field `ShortcutOverride.dictionary` writes, minus the ones with a
    /// bespoke schema below.
    private static let overrideFields = [
        "showMinimized", "showHidden", "showWindowless", "sortOrder", "applicationsOnly",
        "expandBrowserTabsAsWindows", "stayOpenOnRelease", "stayOpenOnQuickTap",
        "layoutMode", "panelScalePercent", "panelAppearance", "fontScale", "fontFace",
        "gridMaxColumns", "listWidthPercent", "panelOpacity", "panelCornerRadius",
        "backdropMaterial", "showWindowTitleLabel", "previewTitleAlignment",
        "titleTruncationMode", "boldSelectedLabel", "showApplicationNames",
        "showUnreadBadges", "letterHintsEnabled",
    ]

    private static func overrideProperties(from base: [String: ConfigSettingDoc]) -> [String: ConfigSettingDoc] {
        var out: [String: ConfigSettingDoc] = [
            "target": ConfigSettingDoc(
                "string", "Which shortcut this entry overrides.",
                pattern: "^(switchApps|switchWindows|scoped\\.[0-9]+)$"),
            "spaceScope": ConfigSettingDoc(
                "string", "Override: which Spaces windows are pulled from. \"inherit\" follows the global spaceScope.",
                values: ConfigValues(SpaceScopeOverride.self, \.displayName)),
            "panelSize": ConfigSettingDoc(
                "string", "Legacy size preset, read once and migrated to panelScalePercent.",
                values: legacyPanelSizes),
        ]
        for field in overrideFields {
            guard let global = base[overrideFieldSources[field] ?? field] else { continue }
            out[field] = stringified(global)
        }
        return out
    }

    /// An override is persisted as a plist `[String: String]`, so `true` is
    /// stored as `"true"` and `120` as `"120"`. Derived from the global key's
    /// own doc, so the two can never describe different things.
    private static func stringified(_ doc: ConfigSettingDoc) -> ConfigSettingDoc {
        switch doc.type {
        case "boolean":
            return ConfigSettingDoc("string", "Override: \(doc.text)", values: ["true", "false"])
        case "integer":
            let bounds = doc.range.map { " Accepted: \($0.lowerBound)…\($0.upperBound)." } ?? ""
            return ConfigSettingDoc(
                "string", "Override: \(doc.text)\(bounds) Written as a decimal string.",
                pattern: "^-?[0-9]+$")
        default:
            return ConfigSettingDoc("string", "Override: \(doc.text)", values: doc.values)
        }
    }

    private static let legacyPanelSizes: ConfigValues = ["small", "standard", "large"]
    private static let bundleIDPattern = "^[A-Za-z0-9.\\-_]+$"

    // MARK: - Keys

    private static let base: [String: ConfigSettingDoc] = [
        // Display
        "displayMode": ConfigSettingDoc(
            "string", "Which monitor the switcher opens on.",
            values: ConfigValues(SwitcherDisplayMode.self, \.displayName)),
        "revealDelayMs": ConfigSettingDoc(
            "integer", "How long the shortcut must be held before the panel appears — a quicker tap switches without showing it (milliseconds).",
            range: Preferences.revealDelayRange),
        "titleRefreshIntervalMs": ConfigSettingDoc(
            "integer", "Delay before window titles in the open switcher catch up after an app renames one (milliseconds). Lower reacts sooner, higher costs less CPU.",
            range: Preferences.titleRefreshIntervalRange),

        // Layout & appearance
        "layoutMode": ConfigSettingDoc(
            "string", "Switcher layout: list rows, an icon grid, or window previews.",
            values: ConfigValues(SwitcherLayoutMode.self, \.displayName)),
        "panelScalePercent": ConfigSettingDoc(
            "integer", "Overall size of the switcher panel, in percent.",
            range: Preferences.panelScalePercentRange),
        "listWidthPercent": ConfigSettingDoc(
            "integer", "Width of list rows as a percentage of the automatic, screen-scaled width.",
            range: Preferences.listWidthPercentRange),
        "gridMaxColumns": ConfigSettingDoc(
            "integer", "Column cap for the grid layout. 0 = automatic (as many as fit).",
            range: Preferences.gridMaxColumnsRange),
        "panelAppearance": ConfigSettingDoc(
            "string", "Light or dark switcher, independent of the rest of macOS.",
            values: ConfigValues(PanelAppearance.self, \.displayName)),
        "panelOpacity": ConfigSettingDoc(
            "integer", "Opacity of the panel background, in percent.",
            range: Preferences.panelOpacityRange),
        "panelCornerRadius": ConfigSettingDoc(
            "integer", "Panel corner radius in points. 0 = automatic (follows the panel size), -1 = square corners.",
            range: Preferences.panelCornerRadiusRange),
        "backdropMaterial": ConfigSettingDoc(
            "string", "Blur material behind the rows. Ignored by the macOS 26 glass backdrop.",
            values: ConfigValues(BackdropMaterial.self, \.displayName)),
        "fontScale": ConfigSettingDoc(
            "string", "Size of the name/title text, independent of the panel scale.",
            values: ConfigValues(SwitcherFontScale.self, \.displayName)),
        "fontFace": ConfigSettingDoc(
            "string", "Typeface used for names and titles.",
            values: ConfigValues(SwitcherFontFace.self, \.displayName)),
        "boldSelectedLabel": ConfigSettingDoc("boolean", "Show the highlighted entry's title in bold."),
        "showWindowTitleLabel": ConfigSettingDoc("boolean", "Show each window's title, not just its app."),
        "showApplicationNames": ConfigSettingDoc("boolean", "Show application names next to the icons."),
        "previewTitleAlignment": ConfigSettingDoc(
            "string", "Where the title sits under each window-preview tile.",
            values: ConfigValues(PreviewTitleAlignment.self, \.displayName)),
        "titleTruncationMode": ConfigSettingDoc(
            "string", "Which part of a too-long title is replaced by an ellipsis.",
            values: ConfigValues(TitleTruncationMode.self, \.displayName)),
        "panelSize": ConfigSettingDoc(
            "string", "Legacy size preset, migrated to panelScalePercent at launch. Use panelScalePercent instead.",
            values: legacyPanelSizes),

        // Contents
        "sortOrder": ConfigSettingDoc(
            "string", "Order apps and windows are listed in.",
            values: ConfigValues(SwitcherSortOrder.self, \.displayName)),
        "spaceScope": ConfigSettingDoc(
            "string", "Which Spaces windows are pulled from.",
            values: ConfigValues(SpaceScope.self, \.displayName)),
        "currentSpaceOnly": ConfigSettingDoc(
            "boolean", "Legacy \"only the current Space\" flag, kept in sync with spaceScope for older builds. Edit spaceScope instead."),
        "showMinimizedWindows": ConfigSettingDoc("boolean", "Include minimized windows."),
        "showHiddenApps": ConfigSettingDoc("boolean", "Include apps hidden with ⌘H."),
        "sinkHiddenApps": ConfigSettingDoc("boolean", "Move hidden apps to the bottom of the list instead of leaving them in place."),
        "showWindowlessApps": ConfigSettingDoc("boolean", "Include running apps that have no open window."),
        "applicationsOnly": ConfigSettingDoc("boolean", "Show one entry per app instead of one per window."),
        "windowDrillEnabled": ConfigSettingDoc("boolean", "Peek the highlighted app's windows with ↓ while \"applications only\" is on."),
        "showUnreadBadges": ConfigSettingDoc("boolean", "Show each app's Dock unread badge on its entry."),
        "experimentalUnreadBadges": ConfigSettingDoc(
            "boolean", "Legacy unread-badge flag, read once to seed showUnreadBadges. Edit showUnreadBadges instead."),
        "showRecentlyClosed": ConfigSettingDoc("boolean", "Offer recently closed apps in search so they can be reopened."),
        "recentlyClosedLimit": ConfigSettingDoc(
            "integer", "How many recently closed apps to offer. 0 disables them.",
            range: Preferences.recentlyClosedLimitRange),
        "appExceptions": ConfigSettingDoc(
            "array", "Per-app rules. An app with no entry follows the global settings.",
            item: ConfigItemSchema(
                "object",
                properties: [
                    "bundleID": ConfigSettingDoc(
                        "string", "Bundle identifier of the app this rule applies to.",
                        pattern: bundleIDPattern),
                    "hide": ConfigSettingDoc(
                        "string", "Whether this app is hidden from the switcher.",
                        values: ConfigValues(HideWindowsMode.self, \.displayName)),
                    "ignore": ConfigSettingDoc(
                        "string", "Whether the switcher shortcut is passed through to this app instead of opening the panel.",
                        values: ConfigValues(IgnoreShortcutsMode.self, \.displayName)),
                ],
                required: ["bundleID"])),
        "excludedBundleIDs": ConfigSettingDoc(
            "array", "Legacy always-hidden bundle IDs, folded into appExceptions at launch. Edit appExceptions instead.",
            item: ConfigItemSchema("string", pattern: bundleIDPattern)),
        "pinnedBundleIDs": ConfigSettingDoc(
            "array", "Bundle IDs pinned to the front of the switcher, in the order they appear.",
            item: ConfigItemSchema("string", pattern: bundleIDPattern)),
        "hideAllExcludedBundleIDs": ConfigSettingDoc(
            "array", "Bundle IDs the \"hide all windows\" shortcut leaves visible.",
            item: ConfigItemSchema("string", pattern: bundleIDPattern)),

        // Tabs
        "tabDrillEnabled": ConfigSettingDoc("boolean", "Peek the highlighted window's tabs with \\."),
        "expandTabsAsWindows": ConfigSettingDoc("boolean", "List native system tabs (Finder, Terminal, TextEdit, …) as separate entries."),
        "expandBrowserTabsAsWindows": ConfigSettingDoc("boolean", "List browser tabs (Safari, Chromium) as separate entries."),
        "browserTabRowLimit": ConfigSettingDoc(
            "integer", "Cap on tab entries per browser window. 0 = unlimited; anything else is taken as 2…16.",
            range: 0...Preferences.browserTabRowLimitRange.upperBound),
        "showBrowserIconOnTabs": ConfigSettingDoc("boolean", "Badge each browser-tab entry's favicon with the source browser's icon."),

        // Search
        "fuzzySearchEnabled": ConfigSettingDoc("boolean", "Type to filter the switcher."),
        "letterHintsEnabled": ConfigSettingDoc("boolean", "Show the letter that jumps to each entry."),
        "letterChainTimeoutMs": ConfigSettingDoc(
            "integer", "How long a typed letter-jump prefix stays active before it expires (milliseconds).",
            range: Preferences.letterChainTimeoutRange),
        "searchDismissMode": ConfigSettingDoc(
            "string", "Whether searching keeps the switcher open after the modifier is released.",
            values: ConfigValues(SearchDismissMode.self, \.displayName)),
        "searchIncludesLaunchableApps": ConfigSettingDoc("boolean", "Include installed apps that aren't running, so search can launch them."),
        "fuzzySearchRankBestMatchFirst": ConfigSettingDoc("boolean", "Sort search results by match quality instead of keeping the list order."),
        "searchExpandsBrowserTabs": ConfigSettingDoc("boolean", "Search browser tab titles too."),

        // Keyboard
        "stayOpenOnRelease": ConfigSettingDoc("boolean", "Keep the switcher open after the modifier is released."),
        "stayOpenOnQuickTap": ConfigSettingDoc("boolean", "Also keep it open after a quick tap of the shortcut."),
        "shiftTapStepsBackward": ConfigSettingDoc("boolean", "Tap Shift while switching to step backwards."),
        "backtickReversesAppSwitching": ConfigSettingDoc("boolean", "Use the window-switch shortcut (⌘`) to step backwards through apps."),
        "vimNavigationEnabled": ConfigSettingDoc("boolean", "Navigate with h/j/k/l as well as the arrow keys."),

        // Mouse
        "scrollToSwitch": ConfigSettingDoc("boolean", "Move the selection by scrolling."),
        "scrollReverseDirection": ConfigSettingDoc("boolean", "Reverse the scroll direction."),
        "clickOutsideToDismiss": ConfigSettingDoc("boolean", "Click outside the panel to dismiss it without switching."),
        "mouseHoverSelectionEnabled": ConfigSettingDoc("boolean", "Highlight the entry under the pointer."),
        "mouseClickSelectionEnabled": ConfigSettingDoc("boolean", "Click an entry to switch to it."),
        "hoverActionsEnabled": ConfigSettingDoc("boolean", "Show action buttons on the entry under the pointer."),
        "hoverShowClose": ConfigSettingDoc("boolean", "Include \"close\" among the hover actions."),
        "hoverShowMinimize": ConfigSettingDoc("boolean", "Include \"minimize\" among the hover actions."),
        "hoverShowMaximize": ConfigSettingDoc("boolean", "Include \"maximize\" among the hover actions."),
        "hoverShowHide": ConfigSettingDoc("boolean", "Include \"hide app\" among the hover actions."),
        "hoverShowQuit": ConfigSettingDoc("boolean", "Include \"quit\" among the hover actions."),
        "hoverShowForceQuit": ConfigSettingDoc("boolean", "Include \"force quit\" among the hover actions."),

        // Shortcuts (the trigger chords themselves are stored outside this file)
        "directActivationBindings": ConfigSettingDoc(
            "array", "Bundle ID activated by each direct-activation slot, in slot order. An empty string leaves the slot unused.",
            count: Preferences.directActivationSlotCount,
            // A bundle ID, or "" for an unused slot.
            item: ConfigItemSchema("string", pattern: "^[A-Za-z0-9.\\-_]*$")),
        "scopedShortcutList": ConfigSettingDoc(
            "array", "Scoped switcher shortcuts — each opens the panel already filtered to one subset of windows.",
            item: ConfigItemSchema(
                "object",
                properties: [
                    "id": ConfigSettingDoc(
                        "string", "Stable id of this entry, as a decimal string. Keys its recorded trigger and its shortcutOverrides entry — never reused.",
                        pattern: "^[0-9]+$"),
                    "scope": ConfigSettingDoc(
                        "string", "Which windows the shortcut shows.",
                        values: ConfigValues(SwitchScope.self, \.displayName)),
                    "name": ConfigSettingDoc(
                        "string", "Name the trigger chord is recorded under (the chord itself is stored outside this file)."),
                ],
                required: ["id", "name"])),
        "scopedShortcutScopes": ConfigSettingDoc(
            "array", "Legacy fixed scoped-shortcut slots, migrated to scopedShortcutList. Edit scopedShortcutList instead.",
            count: Preferences.scopedShortcutSlotCount,
            item: ConfigItemSchema("string", values: ConfigValues(SwitchScope.self, \.displayName))),
        "nextScopedShortcutID": ConfigSettingDoc(
            "integer", "Internal counter for allocating scoped-shortcut ids. Never decreases, so a removed id is never reused. Don't edit."),

        // Windows
        "cycleTileWidths": ConfigSettingDoc("boolean", "Repeating the tile-left/right shortcut cycles the window through half → two-thirds → one-third width."),

        // Feedback & menu bar
        "hideMenuBarIcon": ConfigSettingDoc("boolean", "Hide the menu-bar icon."),
        "hapticOnCommit": ConfigSettingDoc("boolean", "Tap the trackpad when the switcher commits a selection."),
        "soundOnCommit": ConfigSettingDoc("boolean", "Play a sound when the switcher commits a selection."),
        "commitSoundName": ConfigSettingDoc(
            "string", "macOS system sound played on commit. A custom sound file stays on the Mac that chose it.",
            // Sound file names are their own label.
            values: ConfigValues(raw: CommitFeedback.systemSoundNames(), labels: nil)),
        "hideFromScreenSharing": ConfigSettingDoc("boolean", "Keep the switcher panel out of screen recordings and shared screens."),

        // Experimental
        "experimentalSwipeTrigger": ConfigSettingDoc("boolean", "Three-finger trackpad swipe."),
        "swipeMode": ConfigSettingDoc(
            "string", "What the three-finger swipe does.",
            values: ConfigValues(SwipeMode.self, \.displayName)),
        "swipeReverseDirection": ConfigSettingDoc("boolean", "Reverse the swipe direction."),
        "swipeCommitOnRelease": ConfigSettingDoc("boolean", "Commit the swipe selection when the fingers lift."),
        "swipeSensitivity": ConfigSettingDoc(
            "integer", "How far fingers must slide to advance one app. Higher = more sensitive.",
            range: Preferences.swipeSensitivityRange),
        "experimentalInstantSpaceSwitch": ConfigSettingDoc("boolean", "Switch Spaces without the macOS animation."),
        "experimentalBrowserTabMRU": ConfigSettingDoc("boolean", "Track browser tabs in the recency order."),
        "experimentalBrowserTabPreviews": ConfigSettingDoc("boolean", "Show thumbnails for browser tabs."),
        "experimentalLivePreviews": ConfigSettingDoc("boolean", "Keep window previews refreshing while the panel is open. Costs CPU/GPU."),
    ]
}
