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
}

final class AccessibilityWaiter {
    var onTrusted: () -> Void = {}
    private var timer: Timer?

    func start() {
        if AccessibilityCheck.isTrusted {
            onTrusted()
            return
        }
        AccessibilityCheck.promptIfNeeded()
        let t = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AccessibilityCheck.isTrusted {
                timer.invalidate()
                self.timer = nil
                self.onTrusted()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
