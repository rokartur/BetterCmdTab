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

    /// Four-char code identifying our hot keys ('BCmT').
    private static let signature: OSType = {
        "BCmT".utf16.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    /// Replace all registrations with `chords`. Safe to call repeatedly (e.g.
    /// when the user remaps the trigger). Chords that fail to register — for
    /// instance a system-reserved chord whose symbolic hotkey is still enabled —
    /// are skipped; disable the matching symbolic hotkey first.
    func update(_ chords: [Chord]) {
        unregisterAll()
        installHandlerIfNeeded()
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
                Log.hotkey.warning("RegisterEventHotKey failed (status \(status)) for keyCode \(chord.keyCode)")
            }
        }
    }

    /// Remove all hot keys and the shared handler. Call on teardown.
    func uninstall() {
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
                guard err == noErr else { return noErr }
                // This handler is installed on the shared dispatcher target, so
                // Carbon calls it for EVERY app hot key — including the ones
                // BetterShortcuts registers (signature 'SSKS') for the window-
                // management chords. Their numeric ids start at 1 and collide
                // with ours (1 = .nextApp, 2 = .prevApp, …), so without this
                // signature gate a ⌃⌘← tile also fires .nextApp and opens the
                // switcher. Only act on our own 'BCmT' hot keys.
                guard hotKeyID.signature == CarbonHotkeyTrigger.signature else { return noErr }
                let id = hotKeyID.id
                // Carbon dispatches on the main run loop, but hop explicitly so
                // we touch MainActor state safely and match HotkeyTap's pattern.
                DispatchQueue.main.async {
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
