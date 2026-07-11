import AppKit
@preconcurrency import CoreFoundation
import CoreGraphics
import os

/// Experimental companion to `SwipeTrigger`: while the three-finger switcher
/// swipe is enabled, this swallows the system's horizontal "swipe between
/// Spaces" gesture so a three-finger slide drives only the switcher and never
/// also slides Spaces underneath it.
///
/// A session-level `CGEventTap` (the same public mechanism as the hotkey tap)
/// watches the private CGS gesture event stream and returns `nil` for the
/// horizontal dock-swipe (`kIOHIDEventTypeDockSwipe`), which suppresses it
/// before the Dock acts. Vertical dock swipes (Mission Control / App Exposé)
/// are left untouched. The event types and field ids are undocumented — that's
/// why this lives behind the off-by-default Experimental swipe toggle.
/// Like `HotkeyTap`, this object is shared by main-thread lifecycle code and a
/// private tap thread. Cross-thread fields are lock-protected; the owner callback
/// is read and invoked only after hopping to the main actor.
final class SpaceSwipeSuppressor: @unchecked Sendable {

    /// CGEvent-tap lifecycle handles. The tap callback runs on its own thread and
    /// reads `tap` (the disabled-tap re-enable path in `handle`), while
    /// `uninstall()` nils them from main (via `setEnabled` on the experimental
    /// toggle, or `deinit`). `CFRunLoopStop` is async, so the callback can be
    /// mid-`handle` during tear-down — an unsynchronized read/write data race.
    /// Guard every field with the same `OSAllocatedUnfairLock` discipline
    /// `HotkeyTap` uses: copy a ref into a local under the lock, release, then
    /// touch CGEvent/CFRunLoop on the local — never hold the lock across
    /// `CFRunLoopRun`/`CFRunLoopStop`. CF ports and `Thread` are thread-safe
    /// reference types, so `TapPorts` is `@unchecked Sendable`.
    private struct TapPorts: @unchecked Sendable {
        var tap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var tapThread: Thread?
        var tapRunLoop: CFRunLoop?
        var tapThreadFinished: DispatchSemaphore?
    }
    private let ports = OSAllocatedUnfairLock<TapPorts>(initialState: TapPorts())

    /// Fired on the MAIN thread when the tap is being disabled repeatedly in a
    /// tight burst (Accessibility revoked, or a sustained timeout). The owner
    /// (`SwitcherController`) tears this non-essential tap down; it re-arms on
    /// AX re-grant, gated on the swipe pref. Set before `setEnabled(true)`.
    @MainActor var onTapDisabledStorm: () -> Void = {}

    @MainActor init() {}

    /// Storm guard for the tap-disabled re-enable path — identical rationale to
    /// `HotkeyTap.DisableGate`. An active session tap whose process loses
    /// Accessibility trust is disabled by the WindowServer; re-enabling it then
    /// fails and it's disabled again. Re-enabling unconditionally spins this tap
    /// thread in synchronous WindowServer IPC, and because the WindowServer
    /// blocks ALL input on an active tap until the callback returns, the whole
    /// system freezes. So cap rapid consecutive re-enables and bail to the owner
    /// once a burst is seen (see `handle`).
    private struct DisableGate {
        var count = 0
        var lastNs: UInt64 = 0
    }
    private let disableGate = OSAllocatedUnfairLock<DisableGate>(initialState: DisableGate())
    /// Max rapid consecutive re-enables before bailing to main-thread recovery.
    private static let maxRapidReenables = 3
    /// Consecutive disables closer together than this count as one burst; a gap
    /// longer than this resets the counter so isolated timeouts always recover.
    private static let disableBurstWindowNs: UInt64 = 1_000_000_000 // 1s

    /// Undocumented CGS gesture event types and fields (from the IOHID/CGS
    /// private headers; same constants InstantSpaceSwitcher uses).
    private enum CGS {
        static let eventGesture: UInt32 = 29        // kCGSEventGesture
        static let eventDockControl: UInt32 = 30    // kCGSEventDockControl
        static let fieldHIDType: UInt32 = 110       // kCGEventGestureHIDType
        static let fieldSwipeMotion: UInt32 = 123   // kCGEventGestureSwipeMotion
        static let hidDockSwipe: Int64 = 23         // kIOHIDEventTypeDockSwipe
        static let motionHorizontal: Int64 = 1      // kCGGestureMotionHorizontal
    }

    @MainActor
    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { uninstall() }
    }

    private func install() {
        guard ports.withLock({ $0.tap }) == nil else { return }
        // Never create an active session tap while AX is untrusted — it can't be
        // durably enabled and would immediately storm. The owner re-arms via
        // SwitcherController.reinstallHotkeyTap on AX re-grant per the persisted
        // swipe pref, so the desired state is not lost.
        guard AccessibilityCheck.isTrusted else { return }

        let mask: CGEventMask =
            (1 << UInt64(CGS.eventGesture)) | (1 << UInt64(CGS.eventDockControl))

        // Fresh tap → fresh storm counter, so a re-arm after a prior storm (or
        // after an Accessibility re-grant) starts with a clean re-enable budget.
        disableGate.withLock { $0 = DisableGate() }

        // Under a debugger, use a non-blocking listen-only tap so a suspended
        // callback thread can't hard-freeze the WindowServer (see DebuggerCheck /
        // HotkeyTap). Suppression is a no-op while debugging — acceptable.
        let tapOptions: CGEventTapOptions = DebuggerCheck.isAttached ? .listenOnly : .defaultTap

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SpaceSwipeSuppressor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: tapOptions,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: opaqueSelf
        ) else {
            Log.priv.error("Space-swipe suppressor tap failed to create")
            return
        }

        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        // Publish tap/source before starting the worker so the callback's
        // re-enable path sees them on first dispatch.
        ports.withLock {
            $0.tap = port
            $0.runLoopSource = src
        }
        CGEvent.tapEnable(tap: port, enable: true)

        // Run on a dedicated thread so main-thread stalls can't trip the tap's
        // watchdog (same rationale as HotkeyTap).
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        ports.withLock { $0.tapThreadFinished = finished }
        let thread = Thread { [weak self] in
            defer { finished.signal() }
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, src, .commonModes)
            self?.ports.withLock { $0.tapRunLoop = loop }
            // Handshake from inside the active run-loop invocation. Signalling
            // just before CFRunLoopRun leaves a stop-before-run window where
            // teardown can issue an ineffective stop and then wait forever.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                started.signal()
            }
            CFRunLoopRun()
        }
        thread.name = "pro.bettercmdtab.SpaceSwipeSuppressor"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        // `withLockUnchecked`: the closure captures the non-Sendable `Thread`,
        // which the `@Sendable`-bodied `withLock` would reject. Still serialized
        // by the same lock.
        ports.withLockUnchecked { $0.tapThread = thread }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Accessibility revoked → an active session tap can't be durably
            // re-enabled; re-enabling spins this thread in synchronous
            // WindowServer IPC, and the WindowServer blocks ALL input on the tap
            // until the callback returns, so the whole system freezes. Bail on
            // the first disable (cheap local trust check, no XPC) and let the
            // owner tear the tap down — never attempt a single re-enable.
            if !AccessibilityCheck.isTrusted {
                Log.priv.error("Space-swipe tap disabled and Accessibility not trusted — tearing down (no re-enable)")
                DispatchQueue.main.async { [weak self] in self?.onTapDisabledStorm() }
                return Unmanaged.passUnretained(event)
            }
            // Backstop for the AX-trusted timeout-loop case (and the brief race
            // where the trust cache hasn't flipped yet): re-enable the first few
            // disables, but once a burst is detected stop spinning and hand off.
            let now = DispatchTime.now().uptimeNanoseconds
            let storming = disableGate.withLock { gate -> Bool in
                if now &- gate.lastNs > Self.disableBurstWindowNs { gate.count = 0 }
                gate.lastNs = now
                gate.count += 1
                return gate.count > Self.maxRapidReenables
            }
            if storming {
                Log.priv.error("Space-swipe tap disabled repeatedly (storm) — bailing to main-thread recovery")
                DispatchQueue.main.async { [weak self] in self?.onTapDisabledStorm() }
                return Unmanaged.passUnretained(event)
            }
            // Final trust re-check immediately before the re-enable closes the
            // TOCTOU window since the check above (see HotkeyTap for the rationale):
            // calling tapEnable on a just-untrusted active tap is itself a
            // WindowServer-stalling IPC.
            guard AccessibilityCheck.isTrusted else {
                DispatchQueue.main.async { [weak self] in self?.onTapDisabledStorm() }
                return Unmanaged.passUnretained(event)
            }
            // Re-enable inside the lock so a concurrent uninstall() (which nils the
            // ports under the same lock) can't race us into re-enabling a tap it
            // just tore down — see HotkeyTap.handle for the full rationale.
            ports.withLock { state in
                if let tap = state.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let hidType = event.getIntegerValueField(field(CGS.fieldHIDType))
        guard hidType == CGS.hidDockSwipe else { return Unmanaged.passUnretained(event) }

        // Suppress only *real* trackpad swipes (posted by the HID kernel, source
        // pid 0). Our own instant-Space-switch synthetic swipe carries this
        // process's pid — let it through, or this tap would eat it and the
        // jump-to-Space would silently fail whenever the swipe trigger is on.
        if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
            return Unmanaged.passUnretained(event)
        }

        // Suppress only the horizontal Space swipe; pass vertical dock swipes
        // (Mission Control / App Exposé) through untouched.
        let motion = event.getIntegerValueField(field(CGS.fieldSwipeMotion))
        if motion == CGS.motionHorizontal {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// `CGEventField` is a `uint32_t`-backed enum; the gesture field ids aren't
    /// declared cases, so bit-cast the raw value to address them.
    private func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }

    @MainActor
    func uninstall() {
        // Snapshot the handles under the lock, then nil them out in the SAME
        // critical section so the callback thread never observes a torn state.
        // Every CGEvent/CFRunLoop call below runs on the locals outside the lock
        // — `CFRunLoopStop` is async and must never be held across the lock.
        let snapshot = ports.withLock { current -> TapPorts in
            let copy = current
            current = TapPorts()
            return copy
        }
        if let tap = snapshot.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let loop = snapshot.tapRunLoop {
            if let runLoopSource = snapshot.runLoopSource {
                CFRunLoopRemoveSource(loop, runLoopSource, .commonModes)
            }
            CFRunLoopStop(loop)
        }
        // The callback uses an unretained C refcon. Wait for the private run loop
        // to exit so deinit cannot free self while a callback is still in-flight.
        if let thread = snapshot.tapThread,
           thread !== Thread.current,
           let finished = snapshot.tapThreadFinished {
            finished.wait()
        }
    }

    deinit {
        MainActor.assumeIsolated { uninstall() }
    }
}
