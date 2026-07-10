import Testing
@testable import BetterCmdTab

@Suite("Switcher session routing")
struct SwitcherSessionRoutingTests {
    @Test func backtickReverseOnlyAppliesToAppSwitchSessionsWhenEnabled() {
        #expect(SwitcherController.windowTriggerStepsAppsBackward(
            session: .appSwitching,
            backtickReversesAppSwitching: true
        ))
        #expect(!SwitcherController.windowTriggerStepsAppsBackward(
            session: .appSwitching,
            backtickReversesAppSwitching: false
        ))
        #expect(!SwitcherController.windowTriggerStepsAppsBackward(
            session: .windowSwitching,
            backtickReversesAppSwitching: true
        ))
        #expect(!SwitcherController.windowTriggerStepsAppsBackward(
            session: .none,
            backtickReversesAppSwitching: true
        ))
    }
}
