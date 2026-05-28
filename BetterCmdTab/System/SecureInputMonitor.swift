import AppKit
import Carbon.HIToolbox
import os

/// Polls `IsSecureEventInputEnabled()` on the main thread and emits a log
/// when the state transitions. Secure event input is a macOS feature that
/// some apps (KeePassXC, password managers, login windows, terminals with
/// secure-keyboard-entry on) engage while a password field is focused.
///
/// While it is engaged, untrusted (non-root) Quartz event taps cannot
/// receive key events — the system delivers them only to the secure
/// process. That means BetterCmdTab's ⌘+Tab tap stops seeing keystrokes
/// and the user hits Dock's native switcher instead. There is no in-app
/// workaround short of shipping a root helper; surfacing the state in
/// the log lets power users diagnose "why didn't BetterCmdTab open?"
/// without guessing.
@MainActor
final class SecureInputMonitor {
    private var timer: Timer?
    private var lastState = false

    func start() {
        lastState = IsSecureEventInputEnabled()
        if lastState {
            Log.hotkey.warning("Secure event input already active at launch; ⌘+Tab tap cannot intercept keys")
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        let now = IsSecureEventInputEnabled()
        guard now != lastState else { return }
        lastState = now
        if now {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            Log.hotkey.warning("Secure event input enabled by \(front, privacy: .public); ⌘+Tab tap suspended")
        } else {
            Log.hotkey.info("Secure event input disabled; ⌘+Tab tap operational")
        }
    }
}
