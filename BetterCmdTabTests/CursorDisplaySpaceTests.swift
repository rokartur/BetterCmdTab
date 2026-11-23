import Testing
@testable import BetterCmdTab

@Suite("Space of the display under the cursor (#260)")
struct CursorDisplaySpaceTests {
    private static func display(_ identifier: String, current: UInt64) -> [String: Any] {
        ["Display Identifier": identifier, "Current Space": ["ManagedSpaceID": current]]
    }

    @Test func picksTheCursorDisplayAmongSeveral() {
        let displays = [Self.display("LEFT-UUID", current: 3), Self.display("RIGHT-UUID", current: 7)]
        #expect(PrivateAPI.currentSpace(ofDisplay: "RIGHT-UUID", in: displays) == 7)
    }

    @Test func sharedSpacesUseTheSingleMainEntry() {
        #expect(PrivateAPI.currentSpace(ofDisplay: "ANY-UUID", in: [Self.display("Main", current: 4)]) == 4)
    }

    @Test func unknownDisplayFallsBack() {
        let displays = [Self.display("LEFT-UUID", current: 3), Self.display("RIGHT-UUID", current: 7)]
        #expect(PrivateAPI.currentSpace(ofDisplay: "GONE-UUID", in: displays) == nil)
    }
}
