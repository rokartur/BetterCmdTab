import AppKit
import Carbon.HIToolbox
import os

final class HotkeyTap {
    enum Event {
        case nextApp
        case prevApp
        case nextWindow
        case prevWindow
        case nextRow
        case prevRow
        case spatialLeft
        case spatialRight
        case moveWindowLeft
        case moveWindowRight
        case moveWindowUp
        case moveWindowDown
        case releaseCmd
        case commit
        case escape
        case closeWindow
        case minimizeWindow
        case hideApp
        case quitApp
        case letterInput(Character)
        case toggleSearch
        case searchInput(Character)
        case searchBackspace
    }

    var onEvent: (Event) -> Void = { _ in }

    /// Delivered (on main) for every keyDown while a shortcut recorder is active.
    /// The tap consumes the original event so the system shortcut (e.g. ⌘Tab)
    /// never fires, then hands the captured event to the recorder.
    var onRecordingKeyDown: (CGEvent) -> Void = { _ in }

    /// Wraps a CGEvent so it can cross the tap-thread → main hop. CGEvent is a
    /// thread-safe CF reference; the box just silences Sendable checking.
    private final class EventBox: @unchecked Sendable {
        let event: CGEvent
        init(_ event: CGEvent) { self.event = event }
    }

    /// User-configurable trigger. Read on the tap thread per-event, written from
    /// MainActor via `updateConfig` — guarded by a lock like the other tap state.
    /// App- and window-switch can carry independent hold modifiers (the two
    /// recorders are independent), so each has its own modifier mask.
    struct Config {
        var appModifier: CGEventFlags
        var appKey: Int64
        var windowModifier: CGEventFlags
        var windowKey: Int64
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var layoutObserver: NSObjectProtocol?

    private let switchingFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let shiftWasHeld = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let layoutData = OSAllocatedUnfairLock<Data?>(initialState: nil)
    /// When true the tap consumes every keyDown (blocking system shortcuts) and
    /// forwards it to `onRecordingKeyDown`. Set while a shortcut recorder is
    /// capturing — required because system-reserved chords like ⌘Tab never reach
    /// an in-app NSEvent monitor, so the recorder must be fed from the tap.
    private let recordingFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// When true the switcher is in fuzzy-search mode: printable keys (incl.
    /// space and the w/m/h/q action letters) become query text and Delete
    /// becomes backspace, instead of driving navigation/actions.
    private let searchModeFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// When true, a discrete mouse-wheel scroll steps the open switcher's
    /// selection. Continuous (trackpad / precise) scrolls are always ignored.
    private let scrollEnabledFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Flip the scroll-to-switch direction.
    private let scrollReverseFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let config = OSAllocatedUnfairLock<Config>(
        initialState: Config(appModifier: .maskCommand, appKey: 48, windowModifier: .maskCommand, windowKey: 50)
    )

    private static let escKey: Int64 = 53
    private static let leftArrow: Int64 = 123
    private static let rightArrow: Int64 = 124
    private static let downArrow: Int64 = 125
    private static let upArrow: Int64 = 126
    private static let returnKey: Int64 = 36
    private static let keypadEnterKey: Int64 = 76
    private static let spaceKey: Int64 = 49
    private static let deleteKey: Int64 = 51
    private static let slashKey: Int64 = 44
    private static let wKey: Int64 = 13
    private static let mKey: Int64 = 46
    private static let hKey: Int64 = 4
    private static let qKey: Int64 = 12

    /// Letters reserved for hotkey actions (close/minimize/hide/quit). UCKey-
    /// Translate may emit one of these on a non-QWERTY layout for a different
    /// physical key — filter so a Dvorak user pressing the "w" physical key
    /// doesn't trigger Close instead of letter-jumping to "w"-labeled row.
    private static let reservedLetters: Set<Character> = ["w", "m", "h", "q"]

    func install() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
            let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: cgEvent)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: opaqueSelf
        ) else {
            return false
        }

        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        // Publish tap/source before starting the worker so the callback's
        // re-enable path sees them on first dispatch.
        tap = port
        runLoopSource = src
        CGEvent.tapEnable(tap: port, enable: true)

        // Run the tap on a dedicated thread. The main run loop stalls during
        // startup (per-app AX observer install, cache warmup, prewarm) and
        // every other point where AX timeouts hold the main thread. When the
        // tap callback fails to drain within ~1s, the kernel watchdog disables
        // the tap and the user's keystroke is dropped — exactly what produced
        // the "first Cmd+Tab after launch does nothing" symptom. A private
        // run loop on a userInteractive thread isolates the tap from any
        // main-thread work and keeps Cmd+Tab responsive immediately.
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, src, .commonModes)
            self?.tapRunLoop = loop
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "pro.bettercmdtab.HotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        tapThread = thread

        loadKeyboardLayout()
        let nc = DistributedNotificationCenter.default()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        layoutObserver = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.loadKeyboardLayout()
        }
        return true
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let loop = tapRunLoop {
            if let runLoopSource {
                CFRunLoopRemoveSource(loop, runLoopSource, .commonModes)
            }
            CFRunLoopStop(loop)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        if let obs = layoutObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            layoutObserver = nil
        }
    }

    deinit {
        uninstall()
    }

    /// Set by SwitcherController when phase transitions. Read by the tap
    /// callback from arbitrary thread context — `OSAllocatedUnfairLock` makes
    /// the access safe without needing `MainActor.assumeIsolated`.
    func setSwitching(_ value: Bool) {
        switchingFlag.withLock { $0 = value }
    }

    /// Enter/leave recording mode. While recording, keyDowns are consumed and
    /// forwarded to `onRecordingKeyDown` instead of driving the switcher.
    func setRecording(_ value: Bool) {
        recordingFlag.withLock { $0 = value }
    }

    /// Enter/leave fuzzy-search mode. Read by the tap callback to reroute
    /// printable keystrokes into the search query.
    func setSearchMode(_ value: Bool) {
        searchModeFlag.withLock { $0 = value }
    }

    /// Enable/disable stepping the open switcher with a mouse scroll wheel.
    func setScrollEnabled(_ value: Bool) {
        scrollEnabledFlag.withLock { $0 = value }
    }

    /// Flip the scroll-to-switch direction.
    func setScrollReverse(_ value: Bool) {
        scrollReverseFlag.withLock { $0 = value }
    }

    /// Apply user-chosen modifiers + trigger keys. Safe to call any time; the
    /// tap callback reads the new value on its next event.
    func updateConfig(_ newConfig: Config) {
        config.withLock { $0 = newConfig }
    }

    private func isSwitchingNow() -> Bool {
        switchingFlag.withLock { $0 }
    }

    private func isSearchingNow() -> Bool {
        searchModeFlag.withLock { $0 }
    }

    private func loadKeyboardLayout() {
        guard let sourceRef = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            Log.hotkey.warning("TISCopyCurrentKeyboardInputSource returned nil")
            return
        }
        guard let prop = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData) else {
            Log.hotkey.warning("TISGetInputSourceProperty kTISPropertyUnicodeKeyLayoutData nil")
            return
        }
        let cfData = Unmanaged<CFData>.fromOpaque(prop).takeUnretainedValue()
        let data = cfData as Data
        layoutData.withLock { $0 = data }
    }

    private func translate(keyCode: UInt16) -> Character? {
        let snapshot = layoutData.withLock { $0 }
        guard let data = snapshot else { return nil }
        return data.withUnsafeBytes { raw -> Character? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            let maxLen = 4
            var chars = [UniChar](repeating: 0, count: maxLen)
            var actualLen = 0
            let status = UCKeyTranslate(
                base,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                maxLen,
                &actualLen,
                &chars
            )
            guard status == noErr, actualLen > 0 else { return nil }
            guard let scalar = Unicode.Scalar(chars[0]) else { return nil }
            return Character(scalar)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.hotkey.warning("CGEventTap disabled, re-enabling")
            return Unmanaged.passUnretained(event)
        }

        if recordingFlag.withLock({ $0 }) {
            // Consume keyDowns (so ⌘Tab etc. don't trigger the system switcher)
            // and forward a copy to the recorder. Let modifier changes through.
            if type == .keyDown, let copy = event.copy() {
                let box = EventBox(copy)
                let handler = onRecordingKeyDown
                DispatchQueue.main.async { handler(box.event) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel {
            // Step the open switcher with a discrete mouse wheel. Trackpad and
            // Magic Mouse produce *continuous* (precise) scrolls — pass those
            // straight through so two-finger scrolling stays free and the
            // trackpad keeps its three-finger swipe. Only acts while the
            // switcher is already showing; never opens it from idle.
            guard isSwitchingNow(), scrollEnabledFlag.withLock({ $0 }) else {
                return Unmanaged.passUnretained(event)
            }
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            guard !continuous, delta != 0 else {
                return Unmanaged.passUnretained(event)
            }
            // With macOS natural scrolling, rolling the wheel down gives a
            // negative delta and should advance the selection forward.
            let reverse = scrollReverseFlag.withLock { $0 }
            let forward = (delta < 0) != reverse
            deliver(forward ? .nextApp : .prevApp)
            return nil
        }

        let cfg = config.withLock { $0 }
        let flags = event.flags
        let appModHeld = flags.contains(cfg.appModifier)
        let windowModHeld = flags.contains(cfg.windowModifier)
        // The switcher stays open while either trigger's hold modifier is down.
        let anyModHeld = appModHeld || windowModHeld
        let shiftHeld = flags.contains(.maskShift)
        // Option + arrow (while the switcher is open) moves the highlighted
        // window between displays/Spaces instead of moving the selection. Option
        // is used rather than Shift because Shift already steps the selection
        // backwards (see the flagsChanged handler below).
        let optionHeld = flags.contains(.maskAlternate)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            if appModHeld && keyCode == cfg.appKey {
                let dir: Event = shiftHeld ? .prevApp : .nextApp
                deliver(dir)
                return nil
            }
            if windowModHeld && keyCode == cfg.windowKey {
                let dir: Event = shiftHeld ? .prevWindow : .nextWindow
                deliver(dir)
                return nil
            }
            if anyModHeld && keyCode == Self.escKey {
                deliver(.escape)
                return nil
            }

            if isSwitchingNow() {
                if isSearchingNow() {
                    // Navigation/commit/escape still work; everything printable
                    // (incl. space and w/m/h/q) feeds the query, Delete is
                    // backspace, and `/` toggles search back off.
                    switch keyCode {
                    case Self.leftArrow:
                        deliver(.spatialLeft); return nil
                    case Self.rightArrow:
                        deliver(.spatialRight); return nil
                    case Self.upArrow:
                        deliver(.prevRow); return nil
                    case Self.downArrow:
                        deliver(.nextRow); return nil
                    case Self.returnKey, Self.keypadEnterKey:
                        deliver(.commit); return nil
                    case Self.escKey:
                        deliver(.escape); return nil
                    case Self.deleteKey:
                        deliver(.searchBackspace); return nil
                    case Self.slashKey:
                        deliver(.toggleSearch); return nil
                    default:
                        if let ch = translate(keyCode: UInt16(keyCode)),
                           let scalar = ch.unicodeScalars.first,
                           scalar.value >= 0x20, scalar.value != 0x7F {
                            deliver(.searchInput(ch))
                            return nil
                        }
                        break
                    }
                } else {
                    switch keyCode {
                    case Self.leftArrow:
                        deliver(optionHeld ? .moveWindowLeft : .spatialLeft); return nil
                    case Self.rightArrow:
                        deliver(optionHeld ? .moveWindowRight : .spatialRight); return nil
                    case Self.upArrow:
                        deliver(optionHeld ? .moveWindowUp : .prevRow); return nil
                    case Self.downArrow:
                        deliver(optionHeld ? .moveWindowDown : .nextRow); return nil
                    case Self.returnKey, Self.keypadEnterKey, Self.spaceKey:
                        deliver(.commit); return nil
                    case Self.escKey:
                        deliver(.escape); return nil
                    case Self.slashKey:
                        deliver(.toggleSearch); return nil
                    case Self.wKey:
                        deliver(.closeWindow); return nil
                    case Self.mKey:
                        deliver(.minimizeWindow); return nil
                    case Self.hKey:
                        deliver(.hideApp); return nil
                    case Self.qKey:
                        deliver(.quitApp); return nil
                    default:
                        if let letter = translate(keyCode: UInt16(keyCode)) {
                            let lower = Character(letter.lowercased())
                            if lower.isLetter,
                               let ascii = lower.asciiValue,
                               ascii >= 0x61 && ascii <= 0x7A,
                               !Self.reservedLetters.contains(lower) {
                                deliver(.letterInput(lower))
                                return nil
                            }
                        }
                        break
                    }
                }
            }
        } else if type == .flagsChanged {
            // Detect Shift press transition (off → on) while switcher is open
            // so the user can step backwards without re-pressing Tab.
            let wasShift = shiftWasHeld.withLock { current -> Bool in
                let prev = current
                current = shiftHeld
                return prev
            }
            if anyModHeld && shiftHeld && !wasShift && isSwitchingNow() {
                deliver(.prevApp)
            }
            if !anyModHeld {
                deliver(.releaseCmd)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func deliver(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async {
            handler(event)
        }
    }
}
