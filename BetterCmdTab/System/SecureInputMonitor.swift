import Carbon.HIToolbox
import Foundation

/// Polls `IsSecureEventInputEnabled()` so the app can react when another process
/// grabs Secure Event Input (a focused password field), which makes the CGEvent
/// tap go deaf. There is no notification for the secure-input state, so a poll is
/// the only option. The timer runs only while the switcher is open; while idle,
/// the next trigger performs the state check before it needs the result.
///
/// `IsSecureEventInputEnabled()` is a local HIToolbox call (no XPC), so a 1 s
/// cadence is effectively free while still catching a transition within a second.
@MainActor
final class SecureInputMonitor {
    /// Fired on every transition with the new state. Set before `start()`.
    var onChange: (Bool) -> Void = { _ in }

    private(set) var isActive = false
    private var timer: Timer?

    func start() {
        poll()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Let the kernel coalesce this session-only wakeup with other work; a
        // late poll is covered by the out-of-band `refresh()` on chord fire.
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Force an out-of-band check — e.g. the instant a Carbon chord fires while
    /// we believed secure input was off (a Carbon chord firing at all is itself
    /// evidence the tap was bypassed). Shrinks the poll-gap window.
    @discardableResult
    func refresh() -> Bool {
        poll()
        return isActive
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated deinit {
        // The run loop retains its timers even though the callback holds self
        // weakly. Invalidate so a monitor released without `stop()` leaves no
        // orphan wakeup behind.
        MainActor.assumeIsolated { stop() }
    }

    private func poll() {
        let now = IsSecureEventInputEnabled()
        guard now != isActive else { return }
        isActive = now
        onChange(now)
    }
}
