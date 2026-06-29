import AppKit
import BetterSettings
import BetterShortcuts

@MainActor
final class ShortcutsSettingsViewController: SettingsTabViewController {

    // Unified AltTab-style switcher-shortcut editor (#74): the list of switcher
    // shortcuts (profiles) + each one's inline per-shortcut options.
    private let shortcutsEditorView = ShortcutsEditorView()

    override func setupContent() {
        // Switcher shortcuts — the unified, AltTab-style tabbed editor: the two
        // core triggers (Apps, Windows) plus each user-created scoped shortcut,
        // every one with its own trigger + inline per-shortcut options. Added as a
        // top-level view (not wrapped in a section card) so its own Trigger /
        // Behavior / Appearance cards read as standalone cards, matching the
        // Appearance pane — rather than nesting cards inside a card.
        addArrangedSubview(shortcutsEditorView)
        register(section: shortcutsEditorView, anchor: SettingsAnchor.switching)

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
        // Another pane (Import settings) can rewrite the shortcut list/overrides
        // off-screen; rebuild the editor from the live model on appear.
        shortcutsEditorView.reload()
    }
}
