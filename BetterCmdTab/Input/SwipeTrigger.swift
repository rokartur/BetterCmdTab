import AppKit
import os

/// Experimental: detects a horizontal trackpad swipe and reports a
/// direction so the switcher can be opened/advanced without the keyboard.
///
/// Reads raw trackpad contacts via Apple's private `MultitouchSupport`
/// framework — the same mechanism BetterTouchTool / Swish use. Unlike the public
/// `NSEvent` `.swipe` monitor (which only fires when the user has set Trackpad →
/// "Swipe between pages" to three fingers, and isn't reliably delivered to a
/// background app), this works out of the box and regardless of which app is
/// frontmost.
///
/// The gesture is continuous: while exactly the set number of fingers (3 or 4) stays
/// down, horizontal travel is accumulated and emits one step per
/// `MTGesture.stepDistance` moved, so a single slide can advance several apps.
/// Direction is configurable.
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

    /// `+1` for a slide down a row, `-1` for up. Never fires in one-shot modes.
    var onRowSwipe: (Int) -> Void = { _ in }

    /// Called when the gesture ends (all fingers lifted) and the
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
        MTGesture.setReverse(reverse)
    }

    /// When `true`, lifting all fingers commits the current selection; when
    /// `false` (default) the switcher stays open to commit with a click/Return.
    func setCommitOnRelease(_ commit: Bool) {
        MTGesture.setCommitOnRelease(commit)
    }

    /// Sets how far fingers must travel to advance one app, from a 1–10
    /// sensitivity level. Higher = more sensitive = shorter travel per step.
    func setSensitivity(_ level: Int) {
        MTGesture.setSensitivity(level)
    }

    func setOneShot(_ oneShot: Bool) {
        MTGesture.setOneShot(oneShot)
    }

    func setFingerCount(_ count: Int) {
        MTGesture.setFingerCount(count)
    }

    private func install() {
        guard devices.isEmpty else { return }
        guard let api = MultitouchAPI.shared else {
            Log.priv.error("MultitouchSupport unavailable — swipe trigger disabled")
            return
        }
        guard let list = api.createList()?.takeRetainedValue() else { return }

        SwipeTrigger.active = self
        MTGesture.reset()

        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            // Own the MTDeviceRef for the registration's lifetime. The list
            // array (released at scope exit) holds the only guaranteed retain;
            // MTDeviceStop's run-thread teardown drops the framework's own
            // retain before MTUnregisterContactFrameCallback touches the
            // device, so without this the uninstall path writes to a freed
            // CF object.
            _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
            api.registerCallback(device, multitouchSwipeCallback)
            api.start(device, 0)
            devices.append(device)
        }
        if devices.isEmpty {
            SwipeTrigger.active = nil
        }
    }

    private func uninstall() {
        // Invalidate actions already queued from the private callback before
        // detaching it. Their generation check on main then cannot deliver an
        // old gesture into a later re-enable session.
        MTGesture.reset()
        guard !devices.isEmpty, let api = MultitouchAPI.shared else {
            devices.removeAll()
            if SwipeTrigger.active === self { SwipeTrigger.active = nil }
            return
        }
        for device in devices {
            // Unregister while the device is still valid, then stop; release
            // last — it balances the retain taken in `install()`.
            api.unregisterCallback(device, multitouchSwipeCallback)
            api.stop(device)
            Unmanaged<AnyObject>.fromOpaque(device).release()
        }
        devices.removeAll()
        if SwipeTrigger.active === self { SwipeTrigger.active = nil }
    }

    nonisolated deinit {
        tearDownOnMainActor { uninstall() }
    }

    /// Called on the main actor from the contact callback once a swipe is
    /// recognized; routes to the live trigger's handler.
    fileprivate static func deliver(_ direction: Int) {
        active?.onSwipe(direction)
    }

    fileprivate static func deliverRow(_ direction: Int) {
        active?.onRowSwipe(direction)
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
    /// Keep the image loaded for as long as its function pointers can be called.
    /// A partially-resolved image is closed on the failure path in `load()`.
    private let handle: UnsafeMutableRawPointer

    static let shared: MultitouchAPI? = load()

    private static func load() -> MultitouchAPI? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        var loaded = false
        defer {
            if !loaded { dlclose(handle) }
        }
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
        let api = MultitouchAPI(
            createList: createList,
            registerCallback: register,
            unregisterCallback: unregister,
            start: start,
            stop: stop,
            handle: handle
        )
        loaded = true
        return api
    }
}

// MARK: - Gesture recognition (runs on the MultitouchSupport callback thread)

/// Byte layout of the contact-frame struct, stable across macOS releases:
/// the `normalized` readout (position then velocity, each two `Float`s) starts
/// at offset 32, so the normalized position x lives at 32 and y at 36. Each
/// contact is 96 bytes. We only read the normalized position, so we avoid
/// mirroring the rest.
private enum MTLayout {
    static let stride = 96
    static let normalizedPosX = 32
    static let normalizedPosY = 36
}

/// Per-gesture state shared by MultitouchSupport callbacks and main-actor
/// preference updates. Private-framework callbacks are not documented to use a
/// single thread (and separate devices may call concurrently), so every field —
/// including the read/modify/write accumulator — lives behind one unfair lock.
/// One lock acquisition per contact frame is cheaper than dispatching the frame
/// and makes configuration changes immediately coherent with gesture handling.
enum MTGesture {
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

    /// Normalized horizontal travel needed to trigger a one-shot Space switch.
    static let oneShotThreshold: Float = 0.08
    /// Silence from the latched device beyond this (seconds) lets another device
    /// take over. Gesture frames arrive at ≥60 Hz, so this is far longer than any
    /// real inter-frame gap — only a truly dead device crosses it.
    static let latchStaleWindow: Double = 0.5
    /// Steps wait this long after the fingers land, so a late fourth finger rejects first (#259).
    /// shortcut: 50 ms is a guess, size it from real four-finger landings on a trackpad.
    static let settleWindow: Double = 0.05

    private struct State: Sendable {
        /// Bumped at every install/uninstall/reset boundary. An action carries
        /// the generation that recognized it so a delayed main-queue hop cannot
        /// target a newer trigger session.
        var generation: UInt64 = 1
        var stepDistance = MTGesture.stepDistance(forLevel: defaultSensitivityLevel)
        /// A swipe gesture has begun and not yet fully lifted. Survives a brief
        /// drop below `fingerCount` fingers so finger flicker does not end it.
        var active = false
        var tracking = false
        var lastX: Float = 0
        var lastY: Float = 0
        var accumulator: Float = 0
        var rowAccumulator: Float = 0
        var reverse = false
        var commitOnRelease = false
        var oneShot = false
        var fingerCount = 3
        var fired = false
        /// Set once more than `fingerCount` fingers touch: that touch is another
        /// gesture, such as a four-finger Space swipe (#259), until every finger lifts.
        var rejected = false
        /// The touch on the pad, or the last one to lift, is this gesture's. Kept past the
        /// lift, briefly: a system Space swipe can send phases after the fingers leave.
        var ownsTouch = false
        /// Uptime (ns) when the gesture's own touch lifted.
        var ownedLiftAt: UInt64 = 0
        /// Frame time when the touch first held exactly `fingerCount` fingers.
        var activeSince: Double = 0
        /// Device the current gesture is latched to (`-1` = none).
        var latchedDevice: Int32 = -1
        /// Timestamp of the latched device's most recent frame.
        var latchedAt: Double = 0
    }

    struct Action: Sendable {
        /// Signed number of selection steps. Positive means forward.
        var steps = 0
        /// Signed number of row steps. Positive means down.
        var rows = 0
        var commit = false
        var generation: UInt64 = 0
        static let none = Action()
    }

    private static let state = OSAllocatedUnfairLock<State>(initialState: State())

    static func setReverse(_ reverse: Bool) {
        state.withLock { $0.reverse = reverse }
    }

    static func setCommitOnRelease(_ commit: Bool) {
        state.withLock { $0.commitOnRelease = commit }
    }

    static func setSensitivity(_ level: Int) {
        let distance = stepDistance(forLevel: level)
        state.withLock { $0.stepDistance = distance }
    }

    static func setOneShot(_ oneShot: Bool) {
        state.withLock { $0.oneShot = oneShot }
    }

    static func setFingerCount(_ count: Int) {
        state.withLock { $0.fingerCount = count }
    }

    static func reset() {
        state.withLock { current in
            let config = (
                current.stepDistance,
                current.reverse,
                current.commitOnRelease,
                current.oneShot,
                current.fingerCount
            )
            var nextGeneration = current.generation &+ 1
            if nextGeneration == 0 { nextGeneration = 1 }
            current = State()
            current.generation = nextGeneration
            current.stepDistance = config.0
            current.reverse = config.1
            current.commitOnRelease = config.2
            current.oneShot = config.3
            current.fingerCount = config.4
        }
    }

    /// Read by `SpaceSwipeSuppressor` on its tap thread.
    static var ownsTouch: Bool {
        ownsTouch(now: DispatchTime.now().uptimeNanoseconds)
    }

    /// Ownership outlives the lift by `latchStaleWindow` only: a pad connected after
    /// `install()` sends no frame that would clear it, so its Space swipes must pass.
    static func ownsTouch(now: UInt64) -> Bool {
        state.withLock { s in
            s.ownsTouch && (s.active || now &- s.ownedLiftAt < UInt64(latchStaleWindow * 1_000_000_000))
        }
    }

    static func isCurrent(generation: UInt64) -> Bool {
        generation != 0 && state.withLock { $0.generation == generation }
    }

    /// Consume one contact frame and return work to deliver after releasing the
    /// lock. `position` is pre-read from the callback's transient C buffer, so no
    /// unsafe pointer crosses into the lock closure.
    static func consume(
        device: Int32,
        contactCount: Int32,
        position: (x: Float, y: Float)?,
        timestamp: Double
    ) -> Action {
        state.withLock { state in
            if state.latchedDevice != -1, device != state.latchedDevice {
                guard contactCount >= state.fingerCount,
                      timestamp.isFinite,
                      timestamp - state.latchedAt > latchStaleWindow else {
                    return .none
                }
                state.latchedDevice = -1
                state.tracking = false
                state.active = false
                state.rejected = false
                state.accumulator = 0
                state.rowAccumulator = 0
                state.fired = false
            }
            // A malformed private-framework timestamp must not poison stale-
            // device takeover forever. Preserve the last valid frame time.
            if timestamp.isFinite { state.latchedAt = timestamp }

            if contactCount > state.fingerCount {
                state.rejected = true
                state.active = false
                state.latchedDevice = device
            }

            if !state.rejected, contactCount == state.fingerCount, let position {
                // Reject before latching/storing `lastX`. In one-shot mode a
                // NaN accumulator never crosses either threshold and otherwise
                // remains poisoned until lift.
                guard position.x.isFinite, position.y.isFinite else {
                    state.tracking = false
                    state.accumulator = 0
                    state.rowAccumulator = 0
                    return .none
                }
                state.latchedDevice = device
                if !state.active { state.activeSince = timestamp }
                state.active = true
                state.ownsTouch = true
                if !state.tracking {
                    state.tracking = true
                    state.lastX = position.x
                    state.lastY = position.y
                    return .none
                }

                state.accumulator += position.x - state.lastX
                state.rowAccumulator += position.y - state.lastY
                state.lastX = position.x
                state.lastY = position.y
                if timestamp - state.activeSince < settleWindow { return .none }
                let rightward = state.reverse ? -1 : 1

                if state.oneShot {
                    guard !state.fired else { return .none }
                    if state.accumulator >= oneShotThreshold {
                        state.fired = true
                        return Action(steps: rightward, generation: state.generation)
                    }
                    if state.accumulator <= -oneShotThreshold {
                        state.fired = true
                        return Action(steps: -rightward, generation: state.generation)
                    }
                    return .none
                }

                // A step on one axis drops the other axis's drift, so a long
                // horizontal slide never banks a stray row step, and vice versa.
                let physicalSteps = takeWholeSteps(from: &state.accumulator, distance: state.stepDistance)
                if physicalSteps != 0 {
                    state.rowAccumulator = 0
                    return Action(steps: physicalSteps * rightward, generation: state.generation)
                }
                let rowSteps = takeWholeSteps(from: &state.rowAccumulator, distance: state.stepDistance)
                if rowSteps != 0 { state.accumulator = 0 }
                // Normalized y grows upward, so an upward slide is a row up (-1).
                return Action(rows: -rowSteps, generation: state.generation)
            }

            if !state.active, contactCount > 0 { state.ownsTouch = false }
            state.tracking = false
            guard contactCount == 0 else { return .none }
            let shouldCommit = state.active && state.commitOnRelease
            if state.active { state.ownedLiftAt = DispatchTime.now().uptimeNanoseconds }
            state.active = false
            state.rejected = false
            state.accumulator = 0
            state.rowAccumulator = 0
            state.fired = false
            state.latchedDevice = -1
            return Action(steps: 0, commit: shouldCommit, generation: state.generation)
        }
    }

    /// Removes the whole steps `accumulator` holds and returns them signed,
    /// in one calculation instead of a loop on the private callback thread.
    private static func takeWholeSteps(from accumulator: inout Float, distance: Float) -> Int {
        guard accumulator.isFinite, distance.isFinite, distance > 0 else {
            accumulator = 0
            return 0
        }
        let quotient = accumulator / distance
        // Normalized contact coordinates make |quotient| tiny. Clamp a
        // malformed private-framework frame so conversion cannot trap or
        // enqueue an unbounded burst onto the main thread.
        let bounded = min(16, max(-16, quotient))
        let steps = Int(bounded.rounded(.towardZero))
        if quotient != bounded {
            accumulator = 0
        } else if steps != 0 {
            accumulator -= Float(steps) * distance
        }
        return steps
    }
}

/// Hop the frame's coalesced steps to the main actor and into the live trigger.
private func mtEmitSteps(_ signedCount: Int, generation: UInt64, deliver: @escaping @MainActor (Int) -> Void) {
    guard signedCount != 0 else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard MTGesture.isCurrent(generation: generation) else { return }
            let direction = signedCount > 0 ? 1 : -1
            for _ in 0..<abs(signedCount) {
                deliver(direction)
            }
        }
    }
}

/// Hop a commit (gesture released) to the main actor.
private func mtEmitCommit(generation: UInt64) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard MTGesture.isCurrent(generation: generation) else { return }
            SwipeTrigger.deliverCommit()
        }
    }
}

/// `@convention(c)` contact-frame callback. Non-capturing, so it can be passed
/// as a C function pointer. While the set fingers stay down it accumulates
/// horizontal and vertical travel and emits one step per `stepDistance` moved,
/// so continuing to slide keeps moving the selection. When all fingers lift it
/// optionally commits the selection.
private func multitouchSwipeCallback(
    _ device: Int32,
    _ contacts: UnsafeRawPointer?,
    _ numContacts: Int32,
    _ timestamp: Double,
    _ frame: Int32
) -> Int32 {
    var position: (x: Float, y: Float)?
    if let contacts, numContacts >= 3 {
        // Average the normalized position of the first three contacts.
        var sumX: Float = 0
        var sumY: Float = 0
        for i in 0..<3 {
            let base = contacts.advanced(by: i * MTLayout.stride)
            sumX += base.loadUnaligned(fromByteOffset: MTLayout.normalizedPosX, as: Float.self)
            sumY += base.loadUnaligned(fromByteOffset: MTLayout.normalizedPosY, as: Float.self)
        }
        position = (sumX / 3, sumY / 3)
    }
    let action = MTGesture.consume(
        device: device,
        contactCount: numContacts,
        position: position,
        timestamp: timestamp
    )
    mtEmitSteps(action.steps, generation: action.generation, deliver: SwipeTrigger.deliver)
    mtEmitSteps(action.rows, generation: action.generation, deliver: SwipeTrigger.deliverRow)
    if action.commit { mtEmitCommit(generation: action.generation) }
    return 0
}
