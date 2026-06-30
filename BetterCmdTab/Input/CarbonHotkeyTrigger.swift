import AppKit
import Carbon.HIToolbox
import os

/// Secure-input-immune trigger that backs the `CGEventTap`.
///
/// A `CGEventTap` stops receiving `keyDown` events whenever another app holds
/// Secure Event Input (a focused password field, e.g. KeePassXC's unlock
/// screen — Apple TN2150). In that state our tap never sees the Tab keyDown, so
/// it can neither open the switcher nor consume the chord, and the native ⌘Tab
/// switcher fires instead (issue #7). A Carbon hot key registered with
/// `RegisterEventHotKey` is dispatched by the system to the registering app and
/// keeps firing under Secure Event Input, so it opens/steps the switcher there.
///
/// Under normal input the head-insert session tap consumes the chord before the
/// WindowServer dispatches the hot key, so this never double-fires; it only
/// "wins" when the tap is bypassed. Pair it with
/// `PrivateAPI.setNativeCommandTabEnabled(false, …)` so the native switcher
/// stays suppressed in the secure-input case too.
@MainActor
final class CarbonHotkeyTrigger {
    /// Delivered (on main) when a registered chord fires. Maps to the same
    /// events the tap produces so `SwitcherController.handle(_:)` is reused.
    var onEvent: (HotkeyTap.Event) -> Void = { _ in }

    /// A chord to register: a Carbon keycode + Carbon modifier mask (cmdKey,
    /// shiftKey, …) and the switcher event it should emit.
    struct Chord {
        let keyCode: UInt32
        let modifiers: UInt32
        let event: HotkeyTap.Event
    }

    private struct Registration {
        let ref: EventHotKeyRef
        let event: HotkeyTap.Event
    }

    private var registrations: [UInt32: Registration] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextId: UInt32 = 1

    /// Bumped on every `update(_:)` so a queued retry from a superseded call
    /// bails instead of registering stale chords. Also lets `uninstall()`
    /// invalidate any in-flight retry.
    private var generation: UInt64 = 0
    /// Backoff for re-registering chords that failed the first attempt. A
    /// reserved chord (⌘Tab / ⌘`) only registers once the WindowServer has
    /// processed our `CGSSetSymbolicHotKeyEnabled(false)` — an asynchronous IPC,
    /// so the disable issued just before this can lag the registration. Retry on
    /// a short backoff until it lands. ~6 × 50 ms covers the typical propagation
    /// without a visible delay; we give up after that (a permanently failing
    /// chord means the symbol was unavailable and native ⌘Tab is the fallback).
    private static let retryDelay: TimeInterval = 0.05
    private static let maxRegisterRetries = 6

    /// Four-char code identifying our hot keys ('BCmT').
    private static let signature: OSType = {
        "BCmT".utf16.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    /// Replace all registrations with `chords`. Safe to call repeatedly (e.g.
    /// when the user remaps the trigger). Chords that fail to register — for
    /// instance a system-reserved chord whose symbolic-hotkey disable has not yet
    /// propagated through the WindowServer — are retried on a short backoff (see
    /// `scheduleRetry`); a still-failing chord is dropped after `maxRegisterRetries`.
    func update(_ chords: [Chord]) {
        unregisterAll()
        installHandlerIfNeeded()
        generation &+= 1
        let failed = register(chords)
        if !failed.isEmpty {
            scheduleRetry(failed, generation: generation, attempt: 1)
        }
    }

    /// Register `chords`, returning the ones that failed. A failure is usually a
    /// system-reserved chord whose symbolic hotkey is still (transiently) enabled
    /// — the caller retries those.
    private func register(_ chords: [Chord]) -> [Chord] {
        var failed: [Chord] = []
        for chord in chords {
            let id = nextId
            nextId &+= 1
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                chord.keyCode,
                chord.modifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registrations[id] = Registration(ref: ref, event: chord.event)
            } else {
                failed.append(chord)
            }
        }
        return failed
    }

    /// Retry the chords that failed to register, on a short backoff, until they
    /// take or `maxRegisterRetries` is reached. Guarded by `generation` so a newer
    /// `update(_:)` (or `uninstall()`) cancels a stale retry.
    private func scheduleRetry(_ chords: [Chord], generation: UInt64, attempt: Int) {
        guard attempt <= Self.maxRegisterRetries else {
            // Log the exact (keyCode, carbonModifiers) of each still-failing chord —
            // a chord whose native symbolic hotkey has no disable-able id (e.g. the
            // ⌘⇧` reverse-above-tab) stays reserved by macOS and fails forever; the
            // keycodes pin which one so the registration set can drop it (issue #16).
            let failing = chords.map { "\($0.keyCode):\($0.modifiers)" }.joined(separator: ",")
            Log.hotkey.warning("RegisterEventHotKey still failing for \(chords.count) chord(s) after \(Self.maxRegisterRetries) retries: \(failing)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, self.generation == generation else { return }
            let failed = self.register(chords)
            if !failed.isEmpty {
                self.scheduleRetry(failed, generation: generation, attempt: attempt + 1)
            }
        }
    }

    /// Remove all hot keys and the shared handler. Call on teardown.
    func uninstall() {
        generation &+= 1 // invalidate any in-flight retry
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func unregisterAll() {
        for (_, reg) in registrations {
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return OSStatus(eventNotHandledErr) }
                // This handler is installed on the shared dispatcher target, so
                // Carbon calls it for EVERY app hot key — including the ones
                // BetterShortcuts registers (signature 'SSKS') for the window-
                // management / direct-activation / scoped chords. Their numeric
                // ids start at 1 and collide with ours (1 = .nextApp, 2 = .prevApp,
                // …), so this signature gate keeps us from acting on them (a ⌃⌘←
                // tile must not fire .nextApp and open the switcher).
                //
                // Crucially, return `eventNotHandledErr` — NOT noErr — for hot keys
                // that aren't ours. noErr marks the event handled and STOPS Carbon
                // from dispatching it to the other handlers on this shared target;
                // since our handler is installed later (at controller boot) than
                // BetterShortcuts' (at launch), it sits above theirs in the LIFO
                // chain, so a noErr here swallows every 'SSKS' hot key before their
                // handler runs. Under normal input the CGEvent tap consumes
                // window-mgmt before Carbon so this was invisible; under Secure
                // Event Input the tap is deaf and the global window-mgmt fallback
                // relies entirely on this Carbon path — noErr killed it.
                guard hotKeyID.signature == CarbonHotkeyTrigger.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = hotKeyID.id
                // Carbon dispatches hot-key events on the main run loop, so we
                // are already on the main thread — touch MainActor state inline
                // instead of deferring a whole run-loop turn through
                // DispatchQueue.main.async. (HotkeyTap needs that hop because its
                // tap runs on a dedicated background thread; this path does not.)
                MainActor.assumeIsolated {
                    let me = Unmanaged<CarbonHotkeyTrigger>.fromOpaque(userData).takeUnretainedValue()
                    me.dispatch(id: id)
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &handlerRef
        )
    }

    private func dispatch(id: UInt32) {
        guard let reg = registrations[id] else { return }
        onEvent(reg.event)
    }
}
