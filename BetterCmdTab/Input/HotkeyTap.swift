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
        case releaseCmd
        case commit
        case escape
        case closeWindow
        case minimizeWindow
        case hideApp
        case quitApp
        case letterInput(Character)
    }

    var onEvent: (Event) -> Void = { _ in }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var layoutObserver: NSObjectProtocol?

    private let switchingFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let layoutData = OSAllocatedUnfairLock<Data?>(initialState: nil)

    private static let tabKey: Int64 = 48
    private static let escKey: Int64 = 53
    private static let backtickKey: Int64 = 50
    private static let leftArrow: Int64 = 123
    private static let rightArrow: Int64 = 124
    private static let downArrow: Int64 = 125
    private static let upArrow: Int64 = 126
    private static let returnKey: Int64 = 36
    private static let keypadEnterKey: Int64 = 76
    private static let spaceKey: Int64 = 49
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
            (1 << CGEventType.flagsChanged.rawValue)

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
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = src

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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
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

    private func isSwitchingNow() -> Bool {
        switchingFlag.withLock { $0 }
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

        let flags = event.flags
        let cmdHeld = flags.contains(.maskCommand)
        let shiftHeld = flags.contains(.maskShift)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            if cmdHeld && keyCode == Self.tabKey {
                let dir: Event = shiftHeld ? .prevApp : .nextApp
                deliver(dir)
                return nil
            }
            if cmdHeld && keyCode == Self.backtickKey {
                let dir: Event = shiftHeld ? .prevWindow : .nextWindow
                deliver(dir)
                return nil
            }
            if cmdHeld && keyCode == Self.escKey {
                deliver(.escape)
                return nil
            }

            if isSwitchingNow() {
                switch keyCode {
                case Self.leftArrow:
                    deliver(.prevApp); return nil
                case Self.rightArrow:
                    deliver(.nextApp); return nil
                case Self.upArrow:
                    deliver(.prevRow); return nil
                case Self.downArrow:
                    deliver(.nextRow); return nil
                case Self.returnKey, Self.keypadEnterKey, Self.spaceKey:
                    deliver(.commit); return nil
                case Self.escKey:
                    deliver(.escape); return nil
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
        } else if type == .flagsChanged {
            if !cmdHeld {
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
