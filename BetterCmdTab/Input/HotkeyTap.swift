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
        case tileLeft
        case tileRight
        case tileTopLeft
        case tileTopRight
        case tileBottomLeft
        case tileBottomRight
        case maximizeWindow
        case centerWindow
        /// Restore the window to the frame captured before the last arrange/move
        /// (default ⌃⌘⌫). See `Activator.restoreFrame`.
        case restoreWindowFrame
        case releaseCmd
        case commit
        case escape
        /// A click landed outside the open switcher panel. Dismiss without
        /// committing, leaving the current window focused (the tap swallows the
        /// click so it doesn't activate whatever was under the pointer).
        case dismiss
        case closeWindow
        case minimizeWindow
        case hideApp
        case quitApp
        case forceQuitApp
        case enterTabDrill
        case exitTabDrill
        case tabPrev
        case tabNext
        case commitTab
        case letterInput(Character)
        /// Like `letterInput`, but carrying the raw keycode instead of a resolved
        /// character — emitted by the secure-input Carbon-chord path, which has no
        /// layout context. Translated to a character at dispatch (`handle(_:)`).
        case letterInputKey(UInt32)
        case toggleSearch
        case searchInput(Character)
        /// Keycode-carrying counterpart of `searchInput` (see `letterInputKey`).
        case searchInputKey(UInt32)
        case searchBackspace
        /// ⌘F while the switcher is open: toggle native full screen on the
        /// highlighted row's window.
        case fullscreen
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

    /// The CGEvent-tap lifecycle handles. The tap callback runs on its own
    /// thread and reads `tap`/`auxTap` (the disabled-tap re-enable path in
    /// `handle`), while `uninstall()` nils them from the caller thread (main —
    /// via `reinstallHotkeyTap` on AX re-grant, or `deinit`). `CFRunLoopStop` is
    /// async, so the callback can be mid-`handle` during the tear-down — an
    /// unsynchronized read/write data race. Guard every field with the same
    /// `OSAllocatedUnfairLock` discipline the rest of the cross-thread tap state
    /// uses. Critical sections stay tiny: copy a ref into a local under the lock,
    /// release, then touch CGEvent/CFRunLoop on the local — never hold the lock
    /// across `CFRunLoopRun`/`CFRunLoopStop` or any blocking call. CF ports and
    /// `Thread` are thread-safe reference types, so `TapPorts` is `@unchecked
    /// Sendable` (same rationale and annotation as `EventBox`).
    private struct TapPorts: @unchecked Sendable {
        var tap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        /// Second tap carrying only the pointer events (scroll + mouse-down) that
        /// the switcher consumes *while open*. Created disabled and toggled by
        /// `setSwitching`, so a closed switcher routes no scroll/click traffic
        /// through this process. See `install()`.
        var auxTap: CFMachPort?
        var auxRunLoopSource: CFRunLoopSource?
        var tapThread: Thread?
        var tapRunLoop: CFRunLoop?
    }
    private let ports = OSAllocatedUnfairLock<TapPorts>(initialState: TapPorts())
    private var layoutObserver: NSObjectProtocol?

    private let switchingFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// True only while the switcher panel is actually on screen (`phase ==
    /// .visible`). Distinct from `switchingFlag`, which is also true during the
    /// brief, panel-less `.primed` phase. The in-panel action keys
    /// (close/quit/minimize/hide/fullscreen) and letter-jump are gated on THIS
    /// flag: in `.primed` there is no panel to act on, so the controller no-ops
    /// them anyway — but swallowing the keystroke there would still sink
    /// ⌘W/⌘Q/⌘M/⌘H/⌘F (and bare letters) from the focused app. A `.primed`
    /// stranded by a lost reveal/commit would do so *persistently*, which is the
    /// "Cmd+Q/W stop working after a while" failure (issue #16). Gating on a
    /// genuinely-visible panel makes those keys pass straight through whenever no
    /// panel is up, independent of any timer firing. Pushed from main via
    /// `setPanelPresented`.
    private let panelPresentedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
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
    /// True while the switcher is in browser-tab drill-in. Nav keys reroute to
    /// `.tabPrev`/`.tabNext`, Esc exits the drill, Cmd release commits the tab.
    private let tabDrillFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// When true, a discrete mouse-wheel scroll steps the open switcher's
    /// selection. Continuous (trackpad / precise) scrolls are always ignored.
    private let scrollEnabledFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Flip the scroll-to-switch direction.
    private let scrollReverseFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// When true, a mouse-down outside `switcherFrame` while the switcher is
    /// open dismisses it (the click is swallowed). Off → clicks always pass
    /// through.
    private let clickDismissFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// The open switcher panel's frame in CGEvent global (top-left origin,
    /// y-down) coordinates, so a mouse-down location can be hit-tested on the
    /// tap thread without touching AppKit. `nil` while the panel is hidden.
    /// Published by SwitcherController on present/dismiss and on every relayout.
    private let switcherFrame = OSAllocatedUnfairLock<CGRect?>(initialState: nil)
    /// When true, the *initial* trigger chord (⌘Tab / ⌘`) is passed through to
    /// the focused app instead of opening the switcher — the "Ignore shortcuts"
    /// per-app exception. Recomputed on main from the frontmost app and pushed
    /// here; only consulted while the switcher is idle (an already-open switcher
    /// keeps navigating normally).
    private let suppressTriggerFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Rebindable in-panel action keys (#5): physical keycode → action. Consulted
    /// in the non-search switching branch before the letter-jump fallback, so a
    /// bound key suppresses letter-jumping (same as the old hardcoded W/M/H/Q).
    /// `.quit` escalates to force-quit when Option is held (preserved behavior).
    /// Pushed from main via `setPanelKeyBindings`, derived from BetterShortcuts.
    enum PanelActionKey { case close, minimize, hide, quit, fullscreen }
    /// Populated entirely from BetterShortcuts at launch via
    /// `SwitcherController.pushPanelKeyBindings` (and on every shortcut change) —
    /// BetterShortcuts' `panelClose/Minimize/Hide/Quit` are the single source of
    /// truth, including their defaults. Empty until the first push (which runs
    /// synchronously in `start()` before the tap processes any event).
    private let panelKeyMap = OSAllocatedUnfairLock<[Int64: PanelActionKey]>(initialState: [:])
    /// Rebindable window-management chords (#7): packed chord key (see
    /// `wmChordKey`) → the arrange `Event`. Checked in the switching branch
    /// before the plain-arrow handling. Derived from BetterShortcuts' `window*`
    /// bindings via `setWindowMgmtBindings`; empty until the launch push.
    private let windowMgmtMap = OSAllocatedUnfairLock<[Int: Event]>(initialState: [:])

    /// Pack a (keyCode, modifier-bits) chord into a single dictionary key.
    /// `modBits`: control = 1, option = 2, shift = 4 (Command excluded — it's the
    /// switcher's hold key). Shifting by 3 leaves room for the 3 modifier bits.
    static func wmChordKey(keyCode: Int64, modBits: Int) -> Int {
        (Int(keyCode) << 3) | (modBits & 0b111)
    }

    /// GLOBAL window-management chords (#7), used when the switcher is CLOSED.
    /// Unlike `windowMgmtMap` these keep the FULL modifier set — including
    /// Command, which is not implicitly held outside the switcher — so a bare
    /// ⌃← (Mission Control) never triggers a tile. Matched in the tap so the
    /// arrange fires reliably without depending on a registered global Carbon
    /// hot key. Derived from the same BetterShortcuts `window*` bindings via
    /// `setWindowMgmtGlobalBindings`; empty until the launch push.
    private let windowMgmtFullMap = OSAllocatedUnfairLock<[Int: Event]>(initialState: [:])

    /// Pack a full chord (Command included) into a dictionary key.
    /// `modBits`: control = 1, option = 2, shift = 4, command = 8.
    static func wmFullChordKey(keyCode: Int64, modBits: Int) -> Int {
        (Int(keyCode) << 4) | (modBits & 0b1111)
    }
    /// Boot floor for the switcher trigger. `Config` can't be empty, so this
    /// mirrors BetterShortcuts' `switchApps`/`switchWindows` defaults (⌘Tab/⌘`);
    /// `SwitcherController.pushHotkeyConfig` overwrites it from BetterShortcuts
    /// at launch and on every change, so BetterShortcuts stays authoritative.
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
    // W/M/H/Q are no longer hardcoded here — they live in the rebindable
    // `panelKeyMap` (#5), consulted in the switching branch's default case.
    /// kVK_ANSI_Backslash. Used to drop into browser tab drill-in on the
    /// highlighted row when the experimental pref is enabled.
    private static let backslashKey: Int64 = 42

    /// Letters reserved from letter-jump because they drive an in-panel action.
    /// Recomputed from the live `panelKeyMap` bindings (translated to the current
    /// layout) plus the fixed ⌘F full-screen key — so it tracks whatever the user
    /// assigns in the in-panel keys section instead of a hardcoded W/M/H/Q. The
    /// same set is mirrored to `RowLabels` via `onReservedLettersChanged` so hint
    /// generation and letter-jump stay in agreement. Read on the tap thread,
    /// written on main / the layout-change observer. Defaults to the shipped
    /// bindings (w/m/h/q) + f until the first push.
    private let reservedLetters = OSAllocatedUnfairLock<Set<Character>>(
        initialState: ["w", "m", "h", "q", "f"]
    )

    /// Fired (on the caller's thread — currently always main) whenever the
    /// reserved-letter set is recomputed, so `SwitcherController` can mirror it
    /// into `RowLabels`. Set before the first `setPanelKeyBindings` push.
    var onReservedLettersChanged: ((Set<Character>) -> Void)?

    func install() -> Bool {
        // Always-on tap: only the events we must catch from idle — the trigger
        // chord (keyDown) and modifier tracking (flagsChanged). Keeping this
        // mask minimal means a closed switcher's only system-wide event traffic
        // is the keystrokes/modifiers we genuinely have to inspect.
        let keyMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        // Pointer events (scroll-to-switch + click-outside-to-dismiss) are only
        // consumed while the switcher is OPEN. They live on a second tap that
        // `setSwitching` enables on open and disables on dismiss — so while the
        // switcher is closed (i.e. almost always) high-frequency scroll and
        // trackpad-momentum events are not routed through this process at all.
        let pointerMask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

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
            eventsOfInterest: keyMask,
            callback: callback,
            userInfo: opaqueSelf
        ) else {
            return false
        }

        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        // Publish tap/source before starting the worker so the callback's
        // re-enable path sees them on first dispatch. Lock only around the
        // assignment; `tapEnable` runs on the local `port` outside the lock.
        ports.withLock {
            $0.tap = port
            $0.runLoopSource = src
        }
        CGEvent.tapEnable(tap: port, enable: true)

        // The pointer tap shares the same callback (`handle` dispatches by
        // type). Created disabled; toggled with the switcher's open state. A
        // failure here only loses scroll/click features, not core switching.
        var auxSrc: CFRunLoopSource?
        if let auxPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: pointerMask,
            callback: callback,
            userInfo: opaqueSelf
        ) {
            let s = CFMachPortCreateRunLoopSource(nil, auxPort, 0)
            ports.withLock {
                $0.auxTap = auxPort
                $0.auxRunLoopSource = s
            }
            auxSrc = s
            CGEvent.tapEnable(tap: auxPort, enable: false)
        } else {
            Log.hotkey.warning("Pointer event tap creation failed; scroll-to-switch and click-outside-dismiss inactive")
        }
        let capturedAuxSrc = auxSrc

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
            if let capturedAuxSrc { CFRunLoopAddSource(loop, capturedAuxSrc, .commonModes) }
            self?.ports.withLock { $0.tapRunLoop = loop }
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "pro.bettercmdtab.HotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        // `withLockUnchecked`: the closure captures the non-Sendable `Thread`,
        // which the `@Sendable`-bodied `withLock` would warn on (and reject in
        // Swift 6). The store is still serialized by the same lock.
        ports.withLockUnchecked { $0.tapThread = thread }

        loadKeyboardLayout()
        let nc = DistributedNotificationCenter.default()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        layoutObserver = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.loadKeyboardLayout()
        }
        return true
    }

    func uninstall() {
        // Snapshot the handles under the lock, then nil them out in the SAME
        // critical section so the callback thread never observes a torn state.
        // Every CGEvent/CFRunLoop call below runs on the locals outside the lock
        // — `CFRunLoopStop` is async and must never be held across the lock.
        // `TapPorts` is `@unchecked Sendable`, so the checked `withLock` accepts
        // returning the snapshot.
        let snapshot = ports.withLock { current -> TapPorts in
            let copy = current
            current = TapPorts()
            return copy
        }
        if let tap = snapshot.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let auxTap = snapshot.auxTap {
            CGEvent.tapEnable(tap: auxTap, enable: false)
        }
        if let loop = snapshot.tapRunLoop {
            if let runLoopSource = snapshot.runLoopSource {
                CFRunLoopRemoveSource(loop, runLoopSource, .commonModes)
            }
            if let auxRunLoopSource = snapshot.auxRunLoopSource {
                CFRunLoopRemoveSource(loop, auxRunLoopSource, .commonModes)
            }
            CFRunLoopStop(loop)
        }
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
        // The pointer tap is only needed while the switcher is open; keep it
        // live exactly for that window so idle scroll/click traffic never
        // enters this process. Safe to call from main: `tapEnable` just toggles
        // a flag in the WindowServer for the mach port.
        let auxTap = ports.withLockUnchecked { $0.auxTap }
        if let auxTap {
            CGEvent.tapEnable(tap: auxTap, enable: value)
        }
    }

    /// Mirror `phase == .visible` onto the tap. Read by the in-panel action-key
    /// and letter-jump branches so they only swallow a keystroke when a panel is
    /// actually on screen (see `panelPresentedFlag`). Safe to call from main.
    func setPanelPresented(_ value: Bool) {
        panelPresentedFlag.withLock { $0 = value }
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

    /// Enter/leave browser tab drill-in. Read by the tap callback to reroute
    /// nav keys to `.tabPrev`/`.tabNext` and commit on modifier release.
    func setTabDrillActive(_ value: Bool) {
        tabDrillFlag.withLock { $0 = value }
    }

    /// Enable/disable stepping the open switcher with a mouse scroll wheel.
    func setScrollEnabled(_ value: Bool) {
        scrollEnabledFlag.withLock { $0 = value }
    }

    /// Flip the scroll-to-switch direction.
    func setScrollReverse(_ value: Bool) {
        scrollReverseFlag.withLock { $0 = value }
    }

    /// Enable/disable click-outside-to-dismiss for the open switcher.
    func setClickOutsideDismiss(_ value: Bool) {
        clickDismissFlag.withLock { $0 = value }
    }

    /// Suppress (pass through) the initial trigger chord for the frontmost app —
    /// the "Ignore shortcuts" exception. Pushed from main on frontmost-app and
    /// active-Space changes.
    func setSuppressTrigger(_ value: Bool) {
        suppressTriggerFlag.withLock { $0 = value }
    }

    /// Publish the open switcher panel's frame in CGEvent global (top-left
    /// origin, y-down) coordinates, or `nil` once it's hidden. Read by the tap
    /// callback to hit-test outside clicks.
    func setSwitcherFrame(_ frame: CGRect?) {
        switcherFrame.withLock { $0 = frame }
    }

    /// Apply user-chosen modifiers + trigger keys. Safe to call any time; the
    /// tap callback reads the new value on its next event.
    func updateConfig(_ newConfig: Config) {
        config.withLock { $0 = newConfig }
    }

    /// Replace the rebindable in-panel action-key map (keycode → action). Pushed
    /// from main on launch and on every preference change; read on the tap thread.
    func setPanelKeyBindings(_ map: [Int64: PanelActionKey]) {
        panelKeyMap.withLock { $0 = map }
        recomputeReservedLetters()
    }

    /// Re-derive the reserved-letter set from the current `panelKeyMap` (each
    /// bound keycode — close/minimize/hide/quit/full-screen — translated to the
    /// active layout), then store it and notify `onReservedLettersChanged`. Called
    /// on every binding push and whenever the keyboard layout changes, so reserved
    /// letters always match what the user actually assigned.
    private func recomputeReservedLetters() {
        let map = panelKeyMap.withLock { $0 }
        var collected: Set<Character> = []
        for keyCode in map.keys {
            guard let ch = translate(keyCode: UInt16(keyCode)) else { continue }
            let lower = Character(ch.lowercased())
            if lower.isLetter { collected.insert(lower) }
        }
        let letters = collected
        reservedLetters.withLock { $0 = letters }
        onReservedLettersChanged?(letters)
    }

    /// Replace the rebindable window-management chord map (packed chord → Event).
    /// Pushed from main on launch and on every preference change.
    func setWindowMgmtBindings(_ map: [Int: Event]) {
        windowMgmtMap.withLock { $0 = map }
    }

    /// Replace the GLOBAL (switcher-closed) full-chord window-management map.
    /// Pushed from main whenever the bindings change; empty leaves the default.
    func setWindowMgmtGlobalBindings(_ map: [Int: Event]) {
        windowMgmtFullMap.withLock { $0 = map }
    }

    private func isSwitchingNow() -> Bool {
        switchingFlag.withLock { $0 }
    }

    private func isPanelPresented() -> Bool {
        panelPresentedFlag.withLock { $0 }
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
        // Reserved letters are layout-dependent (a bound keycode maps to a
        // different letter per layout) — re-derive them on every layout change.
        recomputeReservedLetters()
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
            // Copy the ports into locals under the lock, release, then re-enable
            // on the locals — the strong `let`s keep them alive across the call
            // even if `uninstall()` nils the shared state concurrently.
            let (tap, auxTap) = ports.withLockUnchecked { ($0.tap, $0.auxTap) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Re-arm the pointer tap only if it should currently be live (i.e.
            // the switcher is open); otherwise it stays disabled as intended.
            if let auxTap, isSwitchingNow() { CGEvent.tapEnable(tap: auxTap, enable: true) }
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

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // Click-outside-to-dismiss: only while the switcher is open and the
            // feature is enabled. A click inside the panel passes through so row
            // clicks and hover-action buttons keep working; a click outside is
            // swallowed (return nil) and dismisses the switcher, leaving the
            // current window focused instead of activating whatever was clicked.
            guard isSwitchingNow(), clickDismissFlag.withLock({ $0 }),
                  let frame = switcherFrame.withLock({ $0 }) else {
                return Unmanaged.passUnretained(event)
            }
            if frame.contains(event.location) {
                return Unmanaged.passUnretained(event)
            }
            deliver(.dismiss)
            return nil
        }

        let cfg = config.withLock { $0 }
        let flags = event.flags
        let appModHeld = flags.contains(cfg.appModifier)
        let windowModHeld = flags.contains(cfg.windowModifier)
        // The switcher stays open while either trigger's hold modifier is down.
        let anyModHeld = appModHeld || windowModHeld
        let shiftHeld = flags.contains(.maskShift)
        let tabDrillNow = tabDrillFlag.withLock { $0 }
        // Option + arrow (while the switcher is open) moves the highlighted
        // window between displays/Spaces instead of moving the selection. Option
        // is used rather than Shift because Shift already steps the selection
        // backwards (see the flagsChanged handler below).
        let optionHeld = flags.contains(.maskAlternate)
        // Control + arrow (while the switcher is open) arranges the highlighted
        // window on its current screen — tile to a half, maximize, or center —
        // without leaving the switcher. Distinct from Option (move to display).
        let controlHeld = flags.contains(.maskControl)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            // Browser tab drill-in: while drilled, the usual nav chords step
            // through the tab strip instead of the app list. Esc exits the
            // drill (one level up — the panel stays open).
            if tabDrillNow && isSwitchingNow() {
                if anyModHeld && keyCode == cfg.appKey {
                    deliver(shiftHeld ? .tabPrev : .tabNext); return nil
                }
                if keyCode == Self.escKey {
                    deliver(.exitTabDrill); return nil
                }
                if keyCode == Self.leftArrow {
                    deliver(.tabPrev); return nil
                }
                if keyCode == Self.rightArrow {
                    deliver(.tabNext); return nil
                }
                if keyCode == Self.returnKey || keyCode == Self.keypadEnterKey || keyCode == Self.spaceKey {
                    deliver(.commitTab); return nil
                }
                // Backslash toggles the strip back off — same key in/out, so
                // the user can dismiss the drill without reaching for Esc.
                if keyCode == Self.backslashKey {
                    deliver(.exitTabDrill); return nil
                }
                if let ch = translate(keyCode: UInt16(keyCode)), ch == "\\" {
                    deliver(.exitTabDrill); return nil
                }
                // Any other key while drilled is swallowed so it doesn't
                // accidentally fire app-level actions (Q/W/M/H, letter jump).
                return nil
            }
            // "Ignore shortcuts" exception: while idle, let the trigger chord
            // fall through to the focused app instead of opening the switcher.
            // Only when not already switching — an open switcher still navigates.
            let suppressTrigger = !isSwitchingNow() && suppressTriggerFlag.withLock { $0 }
            if appModHeld && keyCode == cfg.appKey {
                if suppressTrigger { return Unmanaged.passUnretained(event) }
                let dir: Event = shiftHeld ? .prevApp : .nextApp
                deliver(dir)
                return nil
            }
            if windowModHeld && keyCode == cfg.windowKey {
                if suppressTrigger { return Unmanaged.passUnretained(event) }
                let dir: Event = shiftHeld ? .prevWindow : .nextWindow
                deliver(dir)
                return nil
            }
            if anyModHeld && keyCode == Self.escKey {
                deliver(.escape)
                return nil
            }
            // GLOBAL window-management chords (switcher CLOSED). Match the full
            // chord — Command included — and arrange the frontmost window via
            // the tap, so it works without a registered global Carbon hot key.
            // The OPEN switcher handles the same physical chord through
            // `windowMgmtMap` (Command dropped) in the switching branch below,
            // so this is gated on not-switching to avoid double handling.
            if !isSwitchingNow() {
                let cmdHeld = flags.contains(.maskCommand)
                let fullBits = (controlHeld ? 1 : 0) | (optionHeld ? 2 : 0)
                    | (shiftHeld ? 4 : 0) | (cmdHeld ? 8 : 0)
                if fullBits != 0 {
                    let chord = Self.wmFullChordKey(keyCode: keyCode, modBits: fullBits)
                    if let wmEvent = windowMgmtFullMap.withLock({ $0[chord] }) {
                        deliver(wmEvent)
                        return nil
                    }
                }
            }
            // Drill-in trigger — backslash while the switcher is open.
            // Controller no-ops if the highlighted row has no tab group or the
            // experimental pref is off, so this is safe to always emit.
            if isSwitchingNow() && keyCode == Self.backslashKey {
                deliver(.enterTabDrill); return nil
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
                    // Rebindable window-management chords (#7): if the current
                    // modifier+key matches a configured chord (default ⌃+arrow),
                    // arrange the highlighted window. Checked before the plain
                    // arrow handling so a bound chord wins; a chord needs ≥1 of
                    // ⌃/⌥/⇧ so bare arrows still navigate.
                    let wmBits = (controlHeld ? 1 : 0) | (optionHeld ? 2 : 0) | (shiftHeld ? 4 : 0)
                    if wmBits != 0 {
                        let chord = Self.wmChordKey(keyCode: keyCode, modBits: wmBits)
                        if let wmEvent = windowMgmtMap.withLock({ $0[chord] }) {
                            deliver(wmEvent)
                            return nil
                        }
                    }
                    switch keyCode {
                    case Self.leftArrow:
                        deliver(optionHeld ? .moveWindowLeft : .spatialLeft)
                        return nil
                    case Self.rightArrow:
                        deliver(optionHeld ? .moveWindowRight : .spatialRight)
                        return nil
                    case Self.upArrow:
                        deliver(optionHeld ? .moveWindowUp : .prevRow)
                        return nil
                    case Self.downArrow:
                        deliver(optionHeld ? .moveWindowDown : .nextRow)
                        return nil
                    case Self.returnKey, Self.keypadEnterKey, Self.spaceKey:
                        deliver(.commit); return nil
                    case Self.escKey:
                        deliver(.escape); return nil
                    case Self.slashKey:
                        deliver(.toggleSearch); return nil
                    default:
                        // Rebindable in-panel action keys (#5). Checked before the
                        // letter-jump fallback so a bound key suppresses jumping,
                        // exactly as the old hardcoded W/M/H/Q did. ⌘+⌥+Q still
                        // escalates Quit to force-quit (SIGKILL). Full screen is
                        // bound here too (default ⌘F) — rebindable like the rest.
                        // Only swallow the in-panel action keys + letter-jump
                        // while a panel is actually on screen. During `.primed`
                        // (switching, but panel not yet presented) the controller
                        // no-ops all of these anyway — yet consuming the keystroke
                        // here would still sink ⌘W/⌘Q/⌘M/⌘H/⌘F and bare letters
                        // from the focused app. A `.primed` stranded by a lost
                        // reveal/commit would do so persistently — the
                        // "Cmd+Q/W stop working after a while" bug (issue #16).
                        // Gating on a visible panel makes them pass through with
                        // no panel up, independent of any timer.
                        if isPanelPresented() {
                            if let action = panelKeyMap.withLock({ $0[keyCode] }) {
                                switch action {
                                case .close: deliver(.closeWindow)
                                case .minimize: deliver(.minimizeWindow)
                                case .hide: deliver(.hideApp)
                                case .quit: deliver(optionHeld ? .forceQuitApp : .quitApp)
                                case .fullscreen: deliver(.fullscreen)
                                }
                                return nil
                            }
                            if let letter = translate(keyCode: UInt16(keyCode)) {
                                // Layout-agnostic drill-in trigger: regardless of
                                // where `\` lives on the physical keyboard (US,
                                // Polish, ISO/JIS), any key that types `\` enters
                                // tab drill-in.
                                if letter == "\\" {
                                    deliver(.enterTabDrill)
                                    return nil
                                }
                                let lower = Character(letter.lowercased())
                                if lower.isLetter,
                                   let ascii = lower.asciiValue,
                                   ascii >= 0x61 && ascii <= 0x7A,
                                   !reservedLetters.withLock({ $0.contains(lower) }) {
                                    deliver(.letterInput(lower))
                                    return nil
                                }
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
            // `.releaseCmd` only means anything while the switcher is open
            // (releasing the hold modifier commits the selection). When idle
            // this fires on *every* modifier release system-wide — every ⌘C/⌘V,
            // every Shift for a capital letter — and each one would dispatch a
            // no-op `commit()` to the main thread. Gate it on switching so idle
            // typing costs nothing on the main run loop.
            if !anyModHeld && isSwitchingNow() {
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
