import AppKit
import BetterSettings
import BetterShortcuts

/// Profiles pane (tab id stays "shortcuts" so saved tab selection survives).
@MainActor
final class ProfilesSettingsViewController: SettingsTabViewController {

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
        // The in-panel action keys (close / minimize / hide / quit / full screen)
        // are edited per profile, inside each profile's "In-panel keys" card in the
        // editor above (#5) — there is no separate global section.
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Another pane (Import settings) can rewrite the shortcut list/overrides
        // off-screen; rebuild the editor from the live model on appear.
        shortcutsEditorView.reload()
    }
}
