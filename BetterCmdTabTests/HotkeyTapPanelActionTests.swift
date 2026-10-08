import Testing
@testable import BetterCmdTab

@Suite("Panel action key mapping")
struct HotkeyTapPanelActionTests {

    @Test func drilledMoveKeysStepTheDrill() {
        for action: HotkeyTap.PanelActionKey in [.left, .up] {
            guard case .tabPrev = HotkeyTap.panelActionEvent(action, optionHeld: false, drilled: true) else {
                Issue.record("\(action) should step the drill back")
                continue
            }
        }
        for action: HotkeyTap.PanelActionKey in [.right, .down] {
            guard case .tabNext = HotkeyTap.panelActionEvent(action, optionHeld: false, drilled: true) else {
                Issue.record("\(action) should step the drill forward")
                continue
            }
        }
    }

    @Test func drilledWindowActionsStillFire() {
        guard case .closeWindow = HotkeyTap.panelActionEvent(.close, optionHeld: false, drilled: true),
              case .minimizeWindow = HotkeyTap.panelActionEvent(.minimize, optionHeld: false, drilled: true),
              case .fullscreen = HotkeyTap.panelActionEvent(.fullscreen, optionHeld: false, drilled: true),
              case .forceQuitApp = HotkeyTap.panelActionEvent(.quit, optionHeld: true, drilled: true)
        else {
            Issue.record("window actions must reach the controller while drilled")
            return
        }
    }

    @Test func undrilledMoveKeysMoveTheSelection() {
        guard case .spatialLeft = HotkeyTap.panelActionEvent(.left, optionHeld: false, drilled: false),
              case .nextRow = HotkeyTap.panelActionEvent(.down, optionHeld: false, drilled: false)
        else {
            Issue.record("move keys outside a drill must move the selection")
            return
        }
    }
}
