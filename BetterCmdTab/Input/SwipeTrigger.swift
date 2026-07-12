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
        MainActor.assumeIsolated { uninstall() }
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
/// at offset 32, so the normalized position x lives at 32. Each contact is 96
/// bytes. We only read normalized x, so we avoid mirroring the rest.
private enum MTLayout {
    static let stride = 96
    static let normalizedPosX = 32
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

    private struct State: Sendable {
        /// Bumped at every install/uninstall/reset boundary. An action carries
        /// the generation that recognized it so a delayed main-queue hop cannot
        /// target a newer trigger session.
        var generation: UInt64 = 1
        var stepDistance = MTGesture.stepDistance(forLevel: defaultSensitivityLevel)
        /// A three-finger gesture has begun and not yet fully lifted. Survives a
        /// brief drop below three fingers so finger flicker does not end it.
        var active = false
        var tracking = false
        var lastX: Float = 0
        var accumulator: Float = 0
        var reverse = false
        var commitOnRelease = false
        var oneShot = false
        var fired = false
        /// Device the current gesture is latched to (`-1` = none).
        var latchedDevice: Int32 = -1
        /// Timestamp of the latched device's most recent frame.
        var latchedAt: Double = 0
    }

    struct Action: Sendable {
        /// Signed number of selection steps. Positive means forward.
        var steps = 0
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

    static func reset() {
        state.withLock { current in
            let config = (
                current.stepDistance,
                current.reverse,
                current.commitOnRelease,
                current.oneShot
            )
            var nextGeneration = current.generation &+ 1
            if nextGeneration == 0 { nextGeneration = 1 }
            current = State()
            current.generation = nextGeneration
            current.stepDistance = config.0
            current.reverse = config.1
            current.commitOnRelease = config.2
            current.oneShot = config.3
        }
    }

    static func isCurrent(generation: UInt64) -> Bool {
        generation != 0 && state.withLock { $0.generation == generation }
    }

    /// Consume one contact frame and return work to deliver after releasing the
    /// lock. `averageX` is pre-read from the callback's transient C buffer, so no
    /// unsafe pointer crosses into the lock closure.
    static func consume(
        device: Int32,
        contactCount: Int32,
        averageX: Float?,
        timestamp: Double
    ) -> Action {
        state.withLock { state in
            if state.latchedDevice != -1, device != state.latchedDevice {
                guard contactCount >= 3,
                      timestamp.isFinite,
                      timestamp - state.latchedAt > latchStaleWindow else {
                    return .none
                }
                state.latchedDevice = -1
                state.tracking = false
                state.active = false
                state.accumulator = 0
                state.fired = false
            }
            // A malformed private-framework timestamp must not poison stale-
            // device takeover forever. Preserve the last valid frame time.
            if timestamp.isFinite { state.latchedAt = timestamp }

            if contactCount >= 3, let averageX {
                // Reject before latching/storing `lastX`. In one-shot mode a
                // NaN accumulator never crosses either threshold and otherwise
                // remains poisoned until lift.
                guard averageX.isFinite else {
                    state.tracking = false
                    state.accumulator = 0
                    return .none
                }
                state.latchedDevice = device
                state.active = true
                if !state.tracking {
                    state.tracking = true
                    state.lastX = averageX
                    return .none
                }

                state.accumulator += averageX - state.lastX
                state.lastX = averageX
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

                // Convert all whole steps in one calculation instead of a pair
                // of potentially long while-loops on the private callback thread.
                guard state.accumulator.isFinite, state.stepDistance.isFinite,
                      state.stepDistance > 0 else {
                    state.accumulator = 0
                    return .none
                }
                let quotient = state.accumulator / state.stepDistance
                // Normalized contact coordinates make |quotient| tiny. Clamp a
                // malformed private-framework frame so conversion cannot trap or
                // enqueue an unbounded burst onto the main thread.
                let bounded = min(16, max(-16, quotient))
                let physicalSteps = Int(bounded.rounded(.towardZero))
                if quotient != bounded {
                    state.accumulator = 0
                } else if physicalSteps != 0 {
                    state.accumulator -= Float(physicalSteps) * state.stepDistance
                }
                return Action(steps: physicalSteps * rightward, generation: state.generation)
            }

            state.tracking = false
            guard contactCount == 0 else { return .none }
            let shouldCommit = state.active && state.commitOnRelease
            state.active = false
            state.accumulator = 0
            state.fired = false
            state.latchedDevice = -1
            return Action(steps: 0, commit: shouldCommit, generation: state.generation)
        }
    }
}

/// Hop the frame's coalesced steps to the main actor and into the live trigger.
private func mtEmitSteps(_ signedCount: Int, generation: UInt64) {
    guard signedCount != 0 else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard MTGesture.isCurrent(generation: generation) else { return }
            let direction = signedCount > 0 ? 1 : -1
            for _ in 0..<abs(signedCount) {
                SwipeTrigger.deliver(direction)
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
    var averageX: Float?
    if let contacts, numContacts >= 3 {
        // Average the normalized x of the first three contacts. Vertical motion
        // is ignored, so a pure three-finger up/down swipe banks no travel and
        // never steps — only the horizontal component drives the selection.
        var sumX: Float = 0
        for i in 0..<3 {
            let base = contacts.advanced(by: i * MTLayout.stride)
            sumX += base.loadUnaligned(fromByteOffset: MTLayout.normalizedPosX, as: Float.self)
        }
        averageX = sumX / 3
    }
    let action = MTGesture.consume(
        device: device,
        contactCount: numContacts,
        averageX: averageX,
        timestamp: timestamp
    )
    mtEmitSteps(action.steps, generation: action.generation)
    if action.commit { mtEmitCommit(generation: action.generation) }
    return 0
}
