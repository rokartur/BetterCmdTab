import AppKit
import BetterSettings

/// Presents the settings window. Lifecycle (lazy creation, activation,
/// free-on-close, robust reopen) is owned by `BetterSettings.SettingsPresenter`;
/// this just wires the catalog and keeps the existing `show()` call sites working.
@MainActor
final class SettingsWindowPresenter {

    static let shared = SettingsWindowPresenter()

    private let presenter = SettingsPresenter(closeBehavior: .releaseOnClose) {
        SettingsCatalog.makeConfiguration()
    }

    /// Observer that reverts the activation policy when the settings window
    /// closes. Re-created on every `show()` because `.releaseOnClose` builds a
    /// fresh window each time.
    private var closeObserver: NSObjectProtocol?

    /// Redraws the window when it comes back from full occlusion. While the
    /// window sits fully covered by other apps, WindowServer may purge its
    /// content surfaces; when the user switches back, the window shape and
    /// glass chrome reappear instantly but the content region composites as a
    /// see-through "stale frame" for up to a second until Core Animation
    /// notices the loss (#146). Forcing a synchronous full redraw at the
    /// earliest visibility transition collapses that gap.
    private var occlusionObserver: NSObjectProtocol?

    /// Window the close observer is attached to, so a `show()` while the window
    /// is already open doesn't re-register (weak — the window is freed on close).
    private weak var observedWindow: NSWindow?

    private init() {}

    func show() {
        // The app normally runs as `.accessory` (no Dock icon, menu-bar only).
        // An accessory app can't pull a window in front of the active app —
        // `NSApp.activate(ignoringOtherApps:)` is weakened for accessory apps on
        // macOS 14+, so Settings opens *behind* whatever's frontmost. Promote to
        // `.regular` so the app can activate as a normal foreground app; revert
        // to `.accessory` once the window closes so the Dock icon doesn't linger.
        NSApp.setActivationPolicy(.regular)
        presenter.show()

        // Resolve the settings window by class, not `NSApp.keyWindow`: on a
        // reopen with an attached sheet (apps picker) or the color panel key,
        // the key window is *not* the settings window, and a sheet never posts
        // `willClose` (dismissed via `endSheet`) — the revert would be lost and
        // the Dock icon would linger for the session.
        let window = NSApp.windows.first { $0 is SettingsWindow }
        observeCloseForPolicyRevert(window)

        // Activate on the next runloop tick. A just-promoted accessory app can't
        // foreground in the same tick the policy changed — the change has to
        // register with the window server first, so a synchronous `activate` is
        // a no-op and the window stays behind. Deferring one tick lets the
        // activation actually raise the window above other apps.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }

    func hide() {
        presenter.hide()
    }

    /// Watch the now-visible settings window for close and drop the app back to
    /// `.accessory`. Keyed off that specific window so a stray close of some
    /// other window (e.g. an apps-picker sheet) doesn't demote us early.
    private func observeCloseForPolicyRevert(_ window: NSWindow?) {
        if let window, window === observedWindow, closeObserver != nil { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        observedWindow = window
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      window.occlusionState.contains(.visible) else { return }
                window.display()
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                if let token = self?.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.closeObserver = nil
                }
                if let token = self?.occlusionObserver {
                    NotificationCenter.default.removeObserver(token)
                    self?.occlusionObserver = nil
                }
                self?.observedWindow = nil
            }
        }
    }
}
