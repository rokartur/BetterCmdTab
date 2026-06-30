import AppKit
import BetterShortcuts

/// A compact, self-contained recorder for a *per-shortcut* in-panel action key
/// (#74). It deliberately differs from `BetterShortcuts.RecorderCocoa`:
///
/// - It does **not** persist to a global `BetterShortcuts.Name`. The recorded
///   value is reported via `onChange` and stored in the shortcut's
///   `ShortcutOverride` (the single source of truth, exported with the settings).
/// - It does **not** reject a shortcut already used elsewhere. A profile's panel
///   key is *meant* to be allowed to match the global default or another profile —
///   only the keycode is used in-panel and ⌘ is held throughout, so there is no
///   live Carbon registration to clash with.
///
/// `nil` means "use the global default". Esc cancels a capture; Delete clears the
/// override back to the global default; hold ⌘ (the modifier held in-panel) and tap
/// a key to record — the stored chord is normalized to ⌘ so the glyph matches what
/// actually fires (in-panel matching is keycode-only).
@MainActor
final class PanelKeyOverrideRecorder: NSButton {
    /// The recorder currently capturing, if any — so starting one stops the other
    /// (only one app-wide key monitor should be live at a time).
    private static weak var active: PanelKeyOverrideRecorder?

    /// End any in-progress capture. Call before the settings UI hides the row that
    /// owns the active recorder (the detail panel is cached, not deallocated, so a
    /// hidden recorder would otherwise keep its app-wide monitor live and capture
    /// the next chord into the no-longer-visible profile's override).
    static func stopActive() { active?.stop() }

    /// Keycodes the switcher consumes BEFORE its `panelKeyMap` (trigger defaults,
    /// nav/commit, search, tab-drill) — binding one would display a chord that
    /// never fires in-panel, so they are rejected at record time. (Return, keypad
    /// Enter, Space, Esc, Tab, backtick, arrows, slash, backslash.)
    private static let reservedKeyCodes: Set<UInt16> = [36, 76, 49, 53, 48, 50, 123, 124, 125, 126, 44, 42]

    private var shortcut: BetterShortcuts.Shortcut?
    private let onChange: (BetterShortcuts.Shortcut?) -> Void
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    private var recording = false { didSet { updateTitle() } }

    init(shortcut: BetterShortcuts.Shortcut?, onChange: @escaping (BetterShortcuts.Shortcut?) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        setContentHuggingPriority(.required, for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 135).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private func updateTitle() {
        if recording {
            title = String(localized: "Press key…")
        } else if let shortcut {
            // `description` is nonisolated and renders the glyphs (e.g. "⌘W").
            title = shortcut.description
        } else {
            title = String(localized: "Use global default")
        }
    }

    @objc private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        guard monitor == nil else { return }
        Self.active?.stop()
        Self.active = self
        recording = true
        // Suspend BetterShortcuts' global Carbon hotkeys for the capture (this
        // soft-unregisters them) — else recording a chord that collides with a
        // registered global hotkey (direct-activation / scoped-switch) would fire
        // it mid-record. The switcher's own triggers run on the CGEvent tap, not
        // the package, so they are unaffected.
        BetterShortcuts.isEnabled = false
        // Swallow keystrokes app-wide while capturing so e.g. ⌘W can't reach a menu
        // item. Mouse-ups are watched too: a click outside the button ends the
        // capture (clicking another row / control), mirroring RecorderCocoa.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if Self.active === self {
            Self.active = nil
            BetterShortcuts.isEnabled = true
        }
        recording = false
    }

    /// Returns `nil` to swallow the event, or the event to let it pass through.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // A click outside the button ends the capture (e.g. selecting another row);
        // the click itself is passed through so it still acts.
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            let point = convert(event.locationInWindow, from: nil)
            if !bounds.insetBy(dx: -3, dy: -3).contains(point) { stop() }
            return event
        }
        guard event.type == .keyDown else { return nil } // swallow flagsChanged silently
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Esc cancels (keeps the current value); Delete / forward-Delete clears the
        // override so the shortcut falls back to the global key.
        if mods.isEmpty, event.keyCode == 53 { stop(); return nil }
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            shortcut = nil; onChange(nil); stop(); return nil
        }
        // Reject keys the switcher reserves before its in-panel action keys — they
        // would display a chord that never fires while switching.
        if Self.reservedKeyCodes.contains(event.keyCode) { NSSound.beep(); return nil }
        // Require ⌘ (the modifier physically held while the panel is open) and
        // normalize the stored chord to ⌘-only, so the displayed glyph matches the
        // keycode-only in-panel match — no misleading ⌥/⌃/⇧ that does nothing.
        guard mods.contains(.command), let recorded = BetterShortcuts.Shortcut(event: event) else {
            NSSound.beep(); return nil
        }
        let normalized = BetterShortcuts.Shortcut(carbonKeyCode: recorded.carbonKeyCode, carbonModifiers: 256) // 256 = cmdKey
        shortcut = normalized; onChange(normalized); stop(); return nil
    }
}
