import AppKit

enum LiquidGlassVariant: Int, CaseIterable, Sendable {
    case regular = 0
    case clear = 1
    case dock = 2
    case appIcons = 3
    case widgets = 4
    case text = 5
    case avPlayer = 6
    case faceTime = 7
    case controlCenter = 8
    case notificationCenter = 9
    case monogram = 10
    case bubbles = 11
    case identity = 12
    case focusBorder = 13
    case focusPlatter = 14
    case keyboard = 15
    case sidebar = 16
    case abuttedSidebar = 17
    case inspector = 18
    case control = 19
    case loupe = 20
    case slider = 21
    case camera = 22
    case cartouchePopover = 23
}

enum ScrimState: Int {
    case off = 0
    case on = 1
}

enum SubduedState: Int {
    case normal = 0
    case subdued = 1
}
