import AppKit
import ApplicationServices

enum AccessibilityCheck {
    @discardableResult
    static func promptIfNeeded() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

@MainActor
final class AccessibilityWaiter {
    /// Fired once, the first time Accessibility trust is observed — boots the
    /// switcher controller.
    var onTrusted: () -> Void = {}

    /// Fired on every trust transition *after* the initial grant: `true` when
    /// re-granted, `false` when revoked at runtime. Without this the waiter was
    /// one-shot, so revoking Accessibility while the app ran left ⌘Tab silently
    /// dead (the CGEvent tap dies on revoke) with no signal and no recovery but
    /// a relaunch. The monitor keeps polling for the app's lifetime so a
    /// revoke/re-grant is noticed and the tap can be re-armed.
    var onTrustChanged: (Bool) -> Void = { _ in }

    private var timer: Timer?
    private var didGrantInitially = false
    private var lastTrusted = false

    func start() {
        if AccessibilityCheck.isTrusted {
            lastTrusted = true
            didGrantInitially = true
            onTrusted()
        } else {
            AccessibilityCheck.promptIfNeeded()
        }
        startMonitor()
    }

    /// Low-frequency trust poll that runs for the app's lifetime.
    /// `AXIsProcessTrusted()` is a cheap local TCC check (no XPC round-trip), so
    /// a 2 s cadence is free while still catching a revoke/re-grant within a
    /// couple of seconds.
    private func startMonitor() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Coalescible: revoke/re-grant detection may arrive up to 0.5 s later,
        // imperceptible for a trust poll but removes an exact idle wakeup.
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated deinit {
        MainActor.assumeIsolated { stop() }
    }

    private func poll() {
        let trusted = AccessibilityCheck.isTrusted
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        if trusted {
            if didGrantInitially {
                onTrustChanged(true)
            } else {
                didGrantInitially = true
                onTrusted()
            }
        } else {
            onTrustChanged(false)
        }
    }
}
