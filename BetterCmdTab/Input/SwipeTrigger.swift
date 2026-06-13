import AppKit
import os

/// Experimental: detects a horizontal three-finger trackpad swipe and reports a
/// direction so the switcher can be opened/advanced without the keyboard.
///
/// Reads raw trackpad contacts via Apple's private `MultitouchSupport`
/// framework — the same mechanism BetterTouchTool / Swish use. Unlike the public
/// `NSEvent` `.swipe` monitor (which only fires when the user has set Trackpad →
/// "Swipe between pages" to three fingers, and isn't reliably delivered to a
/// background app), this works out of the box and regardless of which app is
/// frontmost.
///
/// The gesture is continuous: while three fingers stay down, horizontal travel
/// is accumulated and emits one step per `MTGesture.stepDistance` moved, so a
/// single slide can advance several apps. Direction is configurable.
///
/// Because it's a private framework the symbols and the contact-frame struct
/// layout are undocumented and could change between macOS releases — that's why
/// the feature is off by default and labeled experimental. Everything is loaded
/// with `dlopen`/`dlsym` so a missing or renamed symbol degrades to "feature
/// unavailable" instead of crashing at launch.
@MainActor
final class SwipeTrigger {
    /// `+1` for a swipe that should advance forward, `-1` for backward.
    var onSwipe: (Int) -> Void = { _ in }

    /// Called when a three-finger gesture ends (all fingers lifted) and the
    /// "commit on release" option is on — the switcher commits its selection.
    var onCommit: () -> Void = {}

    /// The currently-installed trigger. The C contact callback can't capture
    /// `self`, so it hops to the main actor and forwards through this.
    fileprivate static weak var active: SwipeTrigger?

    /// Live multitouch devices we registered a callback on (built-in trackpad
    /// plus any Magic Trackpads connected when the feature was enabled).
    private var devices: [UnsafeMutableRawPointer] = []

    /// `true` once a callback is live on at least one multitouch device. Stays
    /// `false` when no trackpad is present (or MultitouchSupport is unavailable),
    /// so the controller can skip arming the space-swipe suppressor — there is no
    /// gesture to suppress, and the native three-finger swipe keeps working.
    var isInstalled: Bool { !devices.isEmpty }

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { uninstall() }
    }

    /// When `true`, sliding right moves the selection left and vice versa.
    func setReverseDirection(_ reverse: Bool) {
        MTGesture.reverse = reverse
    }

    /// When `true`, lifting all fingers commits the current selection; when
    /// `false` (default) the switcher stays open to commit with a click/Return.
    func setCommitOnRelease(_ commit: Bool) {
        MTGesture.commitOnRelease = commit
    }

    /// Sets how far fingers must travel to advance one app, from a 1–10
    /// sensitivity level. Higher = more sensitive = shorter travel per step.
    func setSensitivity(_ level: Int) {
        MTGesture.stepDistance = MTGesture.stepDistance(forLevel: level)
    }

    func setOneShot(_ oneShot: Bool) {
        // Only the scalar `oneShot` flag is written from the main actor (same
        // single-assignment, set-rarely contract as `reverse`/`commitOnRelease`).
        // The RMW latch fields `fired`/`accumulator` are owned solely by the
        // callback thread, which clears them on full lift and re-anchors them on
        // gesture start — writing them here would be a data race against that
        // thread's `+=`/`-=`/toggle, so we deliberately don't.
        MTGesture.oneShot = oneShot
    }

    private func install() {
        guard devices.isEmpty else { return }
        guard let api = MultitouchAPI.shared else {
            Log.priv.error("MultitouchSupport unavailable — three-finger swipe disabled")
            return
        }
        guard let list = api.createList()?.takeRetainedValue() else { return }

        SwipeTrigger.active = self
        MTGesture.reset()

        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            api.registerCallback(device, multitouchSwipeCallback)
            api.start(device, 0)
            devices.append(device)
        }
        if devices.isEmpty {
            SwipeTrigger.active = nil
        }
    }

    private func uninstall() {
        guard !devices.isEmpty, let api = MultitouchAPI.shared else {
            devices.removeAll()
            if SwipeTrigger.active === self { SwipeTrigger.active = nil }
            return
        }
        for device in devices {
            api.stop(device)
            api.unregisterCallback(device, multitouchSwipeCallback)
        }
        devices.removeAll()
        if SwipeTrigger.active === self { SwipeTrigger.active = nil }
    }

    deinit {
        guard !devices.isEmpty, let api = MultitouchAPI.shared else { return }
        for device in devices {
            api.stop(device)
            api.unregisterCallback(device, multitouchSwipeCallback)
        }
    }

    /// Called on the main actor from the contact callback once a swipe is
    /// recognized; routes to the live trigger's handler.
    fileprivate static func deliver(_ direction: Int) {
        active?.onSwipe(direction)
    }

    /// Called on the main actor when a gesture ends and commit-on-release is on.
    fileprivate static func deliverCommit() {
        active?.onCommit()
    }
}

// MARK: - Private MultitouchSupport bindings

/// Opaque device handle (`MTDeviceRef`).
private typealias MTDeviceRef = UnsafeMutableRawPointer

/// `int callback(int device, MTTouch *contacts, int numContacts, double timestamp, int frame)`.
/// `contacts` points at a C array of contact-frame structs; we read fields by
/// explicit byte offset (see `MTGesture`) rather than mirroring the whole struct.
private typealias MTContactCallback = @convention(c) (Int32, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

/// `dlopen`/`dlsym` view of the handful of MultitouchSupport entry points we
/// need. Resolved once; `nil` if the framework or any symbol is missing.
private struct MultitouchAPI: @unchecked Sendable {
    typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    typealias RegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias UnregisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias StartFn = @convention(c) (MTDeviceRef, Int32) -> Void
    typealias StopFn = @convention(c) (MTDeviceRef) -> Void

    let createList: CreateListFn
    let registerCallback: RegisterFn
    let unregisterCallback: UnregisterFn
    let start: StartFn
    let stop: StopFn

    static let shared: MultitouchAPI? = load()

    private static func load() -> MultitouchAPI? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let createList = sym("MTDeviceCreateList", CreateListFn.self),
            let register = sym("MTRegisterContactFrameCallback", RegisterFn.self),
            let unregister = sym("MTUnregisterContactFrameCallback", UnregisterFn.self),
            let start = sym("MTDeviceStart", StartFn.self),
            let stop = sym("MTDeviceStop", StopFn.self)
        else { return nil }
        return MultitouchAPI(
            createList: createList,
            registerCallback: register,
            unregisterCallback: unregister,
            start: start,
            stop: stop
        )
    }
}

// MARK: - Gesture recognition (runs on the MultitouchSupport callback thread)

/// Byte layout of the contact-frame struct, stable across macOS releases:
/// the `normalized` readout (position then velocity, each two `Float`s) starts
/// at offset 32, so the normalized position x lives at 32. Each contact is 96
/// bytes. We only read normalized x, so we avoid mirroring the rest.
private enum MTLayout {
    static let stride = 96
    static let normalizedPosX = 32
}

/// Per-gesture state. MultitouchSupport serializes callbacks onto a single
/// dedicated thread, so all but `reverse`/`commitOnRelease` are only ever
/// touched from that one thread; the `nonisolated(unsafe)` globals reflect that
/// hand-off contract. The two flags are written from the main actor and read
/// here (plain `Bool`, set rarely).
private enum MTGesture {
    /// Normalized horizontal travel (≈ trackpad fraction) per one-app step.
    /// Smaller = more sensitive scrubbing. Written from the main actor when the
    /// sensitivity preference changes and read on the callback thread — same
    /// plain-value, set-rarely contract as `reverse`/`commitOnRelease`.
    nonisolated(unsafe) static var stepDistance: Float = stepDistance(forLevel: defaultSensitivityLevel)

    /// Sensitivity 1 (least) → longest travel per step; 10 (most) → shortest.
    /// The 1–10 level is mapped linearly between these bounds.
    static let leastSensitiveStep: Float = 0.10
    static let mostSensitiveStep: Float = 0.025
    static let defaultSensitivityLevel = 5

    /// Travel per app step for a 1–10 sensitivity level (clamped).
    static func stepDistance(forLevel level: Int) -> Float {
        let clamped = min(10, max(1, level))
        let t = Float(clamped - 1) / 9  // 0 at level 1 … 1 at level 10
        return leastSensitiveStep - t * (leastSensitiveStep - mostSensitiveStep)
    }

    /// A three-finger gesture has begun and not yet fully lifted. Survives a
    /// brief drop below three fingers so finger flicker mid-scrub doesn't end it.
    nonisolated(unsafe) static var active = false
    /// Currently have three fingers down and are accumulating travel.
    nonisolated(unsafe) static var tracking = false
    nonisolated(unsafe) static var lastX: Float = 0
    /// Horizontal travel banked since the last emitted step.
    nonisolated(unsafe) static var accumulator: Float = 0
    nonisolated(unsafe) static var reverse = false
    nonisolated(unsafe) static var commitOnRelease = false

    nonisolated(unsafe) static var oneShot = false
    /// Set once a one-shot gesture has fired; cleared only when all fingers lift,
    /// so a single swipe switches exactly one Space.
    nonisolated(unsafe) static var fired = false
    /// Normalized horizontal travel needed to trigger a one-shot Space switch.
    static let oneShotThreshold: Float = 0.08

    /// Device the current gesture is latched to (`-1` = none). All registered
    /// devices share one callback thread, so without this a resting finger on a
    /// second trackpad would interleave its frames into the gesture state.
    nonisolated(unsafe) static var latchedDevice: Int32 = -1

    /// Contact-frame timestamp of the latched device's most recent frame. Lets a
    /// stalled latch (device disconnected/slept mid-gesture, or a dropped
    /// zero-contact lift frame) be seized by another device instead of pinning
    /// the latch — and swallowing every gesture on every trackpad — forever.
    nonisolated(unsafe) static var latchedAt: Double = 0
    /// Silence from the latched device beyond this (seconds) lets another device
    /// take over. Gesture frames arrive at ≥60 Hz, so this is far longer than any
    /// real inter-frame gap — only a truly dead device crosses it.
    static let latchStaleWindow: Double = 0.5

    static func reset() {
        active = false
        tracking = false
        accumulator = 0
        fired = false
        latchedDevice = -1
        latchedAt = 0
    }
}

/// Hop a single step to the main actor and into the live trigger.
private func mtEmitStep(_ direction: Int) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            SwipeTrigger.deliver(direction)
        }
    }
}

/// Hop a commit (gesture released) to the main actor.
private func mtEmitCommit() {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            SwipeTrigger.deliverCommit()
        }
    }
}

/// `@convention(c)` contact-frame callback. Non-capturing, so it can be passed
/// as a C function pointer. While three fingers stay down it accumulates
/// horizontal travel and emits one step per `stepDistance` moved, so continuing
/// to slide keeps advancing the selection. When all fingers lift it optionally
/// commits the selection.
private func multitouchSwipeCallback(
    _ device: Int32,
    _ contacts: UnsafeRawPointer?,
    _ numContacts: Int32,
    _ timestamp: Double,
    _ frame: Int32
) -> Int32 {
    // One gesture at a time: latch onto the device that first reaches three
    // contacts and ignore every other device until the latched one fully lifts,
    // so a resting finger on a second trackpad can't stall or end the gesture.
    if MTGesture.latchedDevice != -1 && device != MTGesture.latchedDevice {
        // Stale-latch escape: if the latched device went silent (disconnect /
        // sleep / a dropped zero-contact lift frame), a held latch would
        // otherwise swallow every gesture on every trackpad until the pref is
        // toggled. Let a different device that reaches three contacts seize the
        // gesture once the latched one hasn't delivered a frame for a short
        // window; keep ignoring it otherwise (one gesture at a time).
        guard numContacts >= 3, timestamp - MTGesture.latchedAt > MTGesture.latchStaleWindow else {
            return 0
        }
        MTGesture.latchedDevice = -1
        MTGesture.tracking = false
        MTGesture.active = false
        MTGesture.accumulator = 0
        MTGesture.fired = false
    }
    // This frame belongs to (or will establish) the gesture device — refresh the
    // latch's liveness so a genuine ongoing gesture is never seized.
    MTGesture.latchedAt = timestamp

    if let contacts, numContacts >= 3 {
        // Average the normalized x of the first three contacts. Vertical motion
        // is ignored, so a pure three-finger up/down swipe banks no travel and
        // never steps — only the horizontal component drives the selection.
        var sumX: Float = 0
        for i in 0..<3 {
            let base = contacts.advanced(by: i * MTLayout.stride)
            sumX += base.loadUnaligned(fromByteOffset: MTLayout.normalizedPosX, as: Float.self)
        }
        let avgX = sumX / 3

        MTGesture.latchedDevice = device
        MTGesture.active = true
        // (Re)anchor on a fresh gesture or when resuming after a brief flicker
        // below three fingers, so the gap doesn't bank a spurious jump.
        if !MTGesture.tracking {
            MTGesture.tracking = true
            MTGesture.lastX = avgX
            return 0
        }

        MTGesture.accumulator += avgX - MTGesture.lastX
        MTGesture.lastX = avgX

        // Default: moving right (+x) advances the selection right (+1).
        let rightward = MTGesture.reverse ? -1 : 1

        if MTGesture.oneShot {
            // One Space jump per swipe: fire once past the fixed threshold, then
            // latch until all fingers lift (handled below). Sensitivity ignored.
            if !MTGesture.fired {
                if MTGesture.accumulator >= MTGesture.oneShotThreshold {
                    MTGesture.fired = true
                    mtEmitStep(rightward)
                } else if MTGesture.accumulator <= -MTGesture.oneShotThreshold {
                    MTGesture.fired = true
                    mtEmitStep(-rightward)
                }
            }
            return 0
        }

        let step = MTGesture.stepDistance
        while MTGesture.accumulator >= step {
            MTGesture.accumulator -= step
            mtEmitStep(rightward)
        }
        while MTGesture.accumulator <= -step {
            MTGesture.accumulator += step
            mtEmitStep(-rightward)
        }
        return 0
    }

    // Fewer than three fingers: pause accumulation. Only a full lift (zero
    // contacts) ends the gesture — and commits, if the option is on.
    MTGesture.tracking = false
    if numContacts == 0 {
        if MTGesture.active && MTGesture.commitOnRelease {
            mtEmitCommit()
        }
        MTGesture.active = false
        MTGesture.accumulator = 0
        // Re-arm one-shot mode so the next swipe can switch another Space.
        MTGesture.fired = false
        MTGesture.latchedDevice = -1
    }
    return 0
}
