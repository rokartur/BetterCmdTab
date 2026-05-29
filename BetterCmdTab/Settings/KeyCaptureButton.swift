import AppKit
import Carbon.HIToolbox

/// Human-readable label for a physical keycode, resolved against the current
/// keyboard layout (so "W" shows correctly on QWERTY, "Z" on QWERTZ, etc.).
/// Falls back to a name table for non-printable keys and finally to the raw
/// keycode. Used by `KeyCaptureButton` to show a binding.
enum KeyCodeLabel {
    /// Non-printable / special keys that `UCKeyTranslate` returns nothing useful
    /// for. Keyed by kVK_* keycode.
    private static let specialNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_Tab: "Tab",
        kVK_Delete: "Delete",
        kVK_Escape: "Esc",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_ForwardDelete: "⌦",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "Page Up",
        kVK_PageDown: "Page Down",
    ]

    static func label(for keyCode: Int) -> String {
        if let name = specialNames[keyCode] { return name }
        if let ch = printableCharacter(for: UInt16(keyCode)) {
            return ch.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// The character the keycode types on the current layout, no modifiers.
    private static func printableCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let prop = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(prop).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var actualLen = 0
            let status = UCKeyTranslate(
                base, keyCode, UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, 4, &actualLen, &chars
            )
            guard status == noErr, actualLen > 0, let scalar = Unicode.Scalar(chars[0]) else { return nil }
            let c = Character(scalar)
            // Only accept visible characters; control codes fall back to the name table.
            return c.isLetter || c.isNumber || c.isSymbol || c.isPunctuation ? String(c) : nil
        }
    }
}

/// A button that captures a single physical key when clicked — used to rebind
/// the in-panel action keys (#5). BetterShortcuts' recorder rejects
/// modifier-less keys, so this bespoke control captures a bare keypress via a
/// local event monitor (the Settings window is an ordinary key window, so the
/// monitor receives the event — unlike the switcher panel).
@MainActor
final class KeyCaptureButton: NSButton {
    /// Current bound keycode.
    private(set) var keyCode: Int
    /// Invoked with the new keycode when the user captures a key.
    var onCapture: ((Int) -> Void)?

    private var monitor: Any?
    private var isCapturing = false {
        didSet { updateTitle() }
    }

    init(keyCode: Int) {
        self.keyCode = keyCode
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Update the displayed keycode from outside (e.g. a reset-to-defaults).
    func setKeyCode(_ code: Int) {
        keyCode = code
        if !isCapturing { updateTitle() }
    }

    private func updateTitle() {
        title = isCapturing ? "Press a key…" : KeyCodeLabel.label(for: keyCode)
    }

    @objc private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Esc cancels the capture without rebinding.
            if event.keyCode == UInt16(kVK_Escape) {
                self.endCapture()
                return nil
            }
            let code = Int(event.keyCode)
            self.keyCode = code
            self.endCapture()
            self.onCapture?(code)
            return nil
        }
    }

    private func endCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
