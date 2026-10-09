import AppKit

/// The one curve every switcher glide runs on, and the single gate that turns
/// them all into hard cuts. The open/close fade (#208) has its own durations.
///
/// The three motions are not independent: the panel resizes while the row block
/// glides to compensate for that resize (`SwitcherView.glideListContainer`), so
/// retuning one duration alone would desync the block from the window it is
/// riding. Same reason the gate lives here — a motion that stayed behind only
/// `animationsEnabled` would keep moving for someone who asked the system for
/// less motion.
@MainActor
enum SwitcherMotion {
    static let duration: TimeInterval = 0.16
    static let timing = CAMediaTimingFunction(name: .easeOut)

    /// Off when the user turned switcher animations off, or when macOS-wide
    /// Reduce Motion is on. Read per animation, never cached: both settings can
    /// flip while the app runs and neither read is expensive.
    static var isEnabled: Bool {
        Preferences.shared.animationsEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
