import CoreGraphics
import Foundation

/// Detects release of the hold modifier (⌘ by default) while the switcher panel
/// is open under Secure Event Input.
///
/// Under Secure Event Input the CGEvent tap is deaf, so the normal
/// `flagsChanged`-driven commit-on-release never fires; and the Carbon survivor
/// trigger (`RegisterEventHotKey`) only emits *key-pressed*, never a modifier
/// release. The one signal left is the global modifier *state*: Secure Event
/// Input withholds event *delivery* (TN2150), not state *queries*, so
/// `CGEventSource.flagsState` keeps reflecting the physical modifier. We poll it
/// on a short timer, but only while it actually matters (panel open + secure
/// input), so the normal path pays nothing.
///
/// The decision is pure (`modifierReleased` / `holdState`); only the timer and
/// the state read are impure, which keeps the commit-on-release logic testable.
/// Modeled on `SecureInputMonitor`: a plain main-thread timer (it is started and
/// torn down from the main actor).
@MainActor
final class HoldModifierMonitor {
    /// Fired when the hold modifier transitions held → released.
    var onRelease: () -> Void = {}
    /// Fired on any held ↔ released transition with the new state, so the caller
    /// can re-sync which secure-input Carbon chords are registered.
    var onHoldChange: (Bool) -> Void = { _ in }

    private(set) var isHeld = false
    private var mask: CGEventFlags = .maskCommand
    private var timer: Timer?

    /// Tight cadence while the modifier is held, so the commit-on-release edge
    /// stays low-latency.
    private static let heldInterval: TimeInterval = 0.03
    /// Relaxed cadence once released: the panel can stay parked open for an
    /// unbounded time (sticky / stay-open) and we only need to notice the *next*
    /// re-press, so a far slower poll avoids a permanent 33 Hz main-thread wake.
    private static let releasedInterval: TimeInterval = 0.25
    /// Interval the live timer is currently scheduled at, so `poll` only tears it
    /// down and rebuilds it on an actual cadence change.
    private var currentInterval: TimeInterval = HoldModifierMonitor.heldInterval

    /// Pure: did the modifier go from held to released?
    nonisolated static func modifierReleased(previous: Bool, current: Bool) -> Bool {
        previous && !current
    }

    /// Pure: is every bit of `mask` currently down in `flags`?
    nonisolated static func holdState(flags: CGEventFlags, mask: CGEventFlags) -> Bool {
        flags.contains(mask)
    }

    /// Begin polling for the given hold modifier. `assumeHeld` seeds the state so
    /// a panel opened by a held trigger is treated as held immediately — a
    /// switching Carbon chord firing *proves* the modifier is down — independent
    /// of whether the state query happens to work under Secure Event Input on
    /// this OS. Idempotent: a second `start` only updates the mask/seed.
    func start(mask: CGEventFlags, assumeHeld: Bool) {
        self.mask = mask
        isHeld = assumeHeld
        guard timer == nil else { return }
        // Seed the cadence from the seeded state: a panel opened by a held trigger
        // (`assumeHeld == true`) starts at the tight interval so the *first*
        // release is still caught at 30 ms.
        schedule(interval: assumeHeld ? Self.heldInterval : Self.releasedInterval)
    }

    /// (Re)build the poll timer at `interval`, preserving the weak callback and
    /// `.common` run-loop mode. Replaces any existing timer.
    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        currentInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isHeld = false
    }

    nonisolated deinit {
        MainActor.assumeIsolated { stop() }
    }

    private func currentlyHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return Self.holdState(flags: flags, mask: mask)
    }

    private func poll() {
        let now = currentlyHeld()
        guard now != isHeld else { return }
        let wasHeld = isHeld
        isHeld = now
        // Held → released: drop to the slow cadence; released → held: restore the
        // tight one for the next commit-on-release. Reschedule before firing the
        // callbacks, so the new interval is live regardless of whether
        // onHoldChange/onRelease tear the monitor down (stop() then invalidates the
        // just-built timer harmlessly).
        let wanted = now ? Self.heldInterval : Self.releasedInterval
        if wanted != currentInterval {
            schedule(interval: wanted)
        }
        onHoldChange(now)
        if Self.modifierReleased(previous: wasHeld, current: now) {
            onRelease()
        }
    }
}
