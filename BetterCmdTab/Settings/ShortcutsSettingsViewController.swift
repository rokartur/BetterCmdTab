import AppKit
import BetterSettings
import BetterShortcuts

@MainActor
final class ShortcutsSettingsViewController: SettingsTabViewController {

    // Unified AltTab-style switcher-shortcut editor (#74): tabbed selector for the
    // core triggers + each scoped shortcut, with inline per-shortcut options.
    private let shortcutsEditorView = ShortcutsEditorView()

    // Direct-activation slots: a "choose app" button + shortcut recorder per slot.
    private var directButtons: [NSButton] = []
    private var directSlotSheet: AppsPickerSheetWindowController?

    override func setupContent() {
        // Switcher shortcuts — the unified, AltTab-style tabbed editor: the two
        // core triggers (Apps, Windows) plus each user-created scoped shortcut,
        // every one with its own trigger + inline per-shortcut options. Added as a
        // top-level view (not wrapped in a section card) so its own Trigger /
        // Behavior / Appearance cards read as standalone cards, matching the
        // Appearance pane — rather than nesting cards inside a card.
        addArrangedSubview(shortcutsEditorView)
        register(section: shortcutsEditorView, anchor: SettingsAnchor.switching)

        // Direct activation section — global shortcuts that jump straight to a
        // chosen app, bypassing the switcher.
        let direct = addSection(title: String(localized: "Direct activation"), anchor: SettingsAnchor.directActivation)
        addRow(
            to: direct,
            title: String(localized: "Jump straight to an app"),
            subtitle: String(localized: "Give a shortcut to one app — it focuses that app, opening it first if needed."),
            searchItemID: SearchID.directActivation
        )
        for (index, name) in BetterShortcuts.Name.directActivate.enumerated() {
            let recorder = BetterShortcuts.RecorderCocoa(for: name)
            let button = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseDirectApp(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            let stack = NSStackView(views: [button, recorder])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            addRow(to: direct, title: String(localized: "Slot \(index + 1)"), accessory: stack)
            directButtons.append(button)
        }

        // In-panel keys section — the keys that act on the highlighted window
        // while the switcher is open (close / minimize / hide / quit). Recorded
        // with BetterShortcuts; only the key is used in-panel (⌘ is held the
        // whole time), so e.g. ⌘W reads as W while switching. No global hotkey is
        // registered for these — there's no onKeyDown handler — so binding ⌘W
        // doesn't steal Close in other apps.
        let panelKeys = addSection(title: String(localized: "In-panel keys"), anchor: SettingsAnchor.panelKeys)
        addRow(
            to: panelKeys,
            title: String(localized: "Action keys while switching"),
            subtitle: String(localized: "These act on the highlighted window while the switcher is open. ⌘ is held the whole time, so the modifier you record is ignored in-panel."),
            searchItemID: SearchID.panelKeys
        )
        for (name, title) in BetterShortcuts.Name.panelActionKeys {
            addRow(to: panelKeys, title: title, accessory: BetterShortcuts.RecorderCocoa(for: name))
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDirectSlots()
        // Another pane (Import settings) can rewrite the shortcut list/overrides
        // off-screen; rebuild the editor from the live model on appear.
        shortcutsEditorView.reload()
    }

    // MARK: - Direct activation slots

    /// Sync each slot's "choose app" button to its stored bundle ID.
    private func refreshDirectSlots() {
        let bindings = Preferences.shared.directActivationBindings
        for (index, button) in directButtons.enumerated() {
            let bundleID = bindings.indices.contains(index) ? bindings[index] : ""
            if bundleID.isEmpty {
                button.title = String(localized: "Choose…")
                button.image = nil
            } else {
                button.title = Self.appName(forBundleID: bundleID) ?? bundleID
                button.image = Self.appIcon(forBundleID: bundleID)
                button.imagePosition = .imageLeading
            }
        }
    }

    @objc private func chooseDirectApp(_ sender: NSButton) {
        let slot = sender.tag
        guard let window = view.window, directSlotSheet == nil else { return }
        let current = Preferences.shared.directActivationBindings
        let selected: Set<String> = (current.indices.contains(slot) && !current[slot].isEmpty) ? [current[slot]] : []
        let controller = AppsPickerSheetWindowController(
            title: String(localized: "Activate App"),
            prompt: String(localized: "Choose the app this shortcut focuses."),
            selectedBundleIDs: selected,
            singleSelection: true,
            confirmTitle: String(localized: "Choose")
        ) { selection in
            var bindings = Preferences.shared.directActivationBindings
            while bindings.count <= slot { bindings.append("") }
            bindings[slot] = selection.sorted().first ?? ""
            Preferences.shared.directActivationBindings = bindings
        }
        controller.onDidDismiss = { [weak self] in
            self?.directSlotSheet = nil
            self?.refreshDirectSlots()
        }
        directSlotSheet = controller
        controller.present(asSheetFor: window)
    }

    private static func appName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    private static func appIcon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
