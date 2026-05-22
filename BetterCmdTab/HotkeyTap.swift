import AppKit
import Carbon.HIToolbox

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
    var isSwitching: @MainActor () -> Bool = { false }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

    private static let letterKeyCodes: [Int64: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g",
        34: "i", 38: "j", 40: "k", 37: "l",
        45: "n", 31: "o", 35: "p", 15: "r", 1: "s",
        17: "t", 32: "u", 9: "v", 7: "x", 16: "y", 6: "z",
    ]

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
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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

            let switching = MainActor.assumeIsolated { self.isSwitching() }
            if switching {
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
                    if let letter = Self.letterKeyCodes[keyCode] {
                        deliver(.letterInput(letter))
                        return nil
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
