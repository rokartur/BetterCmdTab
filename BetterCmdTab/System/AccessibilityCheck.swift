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

    static func openSystemSettings(anchor: String = "Privacy_Accessibility") {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
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
    /// Fired on the initial grant and every later re-grant.
    var onTrusted: () -> Void = {}

    private var timer: Timer?

    func start() {
        if AccessibilityCheck.isTrusted {
            onTrusted()
        } else {
            AccessibilityCheck.promptIfNeeded()
            waitForTrust()
        }
    }

    /// Poll only while there is no permission. Once trusted, the live event tap
    /// reports a later revoke and sends us back here, so trusted idle does no work.
    func waitForTrust() {
        if AccessibilityCheck.isTrusted {
            stop()
            onTrusted()
            return
        }
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
        guard AccessibilityCheck.isTrusted else { return }
        stop()
        onTrusted()
    }
}
