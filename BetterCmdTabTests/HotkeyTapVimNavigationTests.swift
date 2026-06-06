import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the h/j/k/l → nav event mapping that the hotkey tap
/// applies when the user opts into vim-style navigation. The mapping has to
/// mirror the bare arrow keys exactly — h↔←, l↔→, k↔↑, j↔↓ — so this pins each
/// pair and makes sure no unrelated character starts behaving like an arrow.
@Suite("Vim navigation key mapping")
struct HotkeyTapVimNavigationTests {

    /// Tag each navigation `Event` case the vim mapping can produce so the
    /// tests can compare without the enum having to conform to `Equatable`
    /// (the real enum carries associated-value cases that don't).
    private enum NavTag {
        case left, right, up, down
    }

    private static func tag(_ event: HotkeyTap.Event?) -> NavTag? {
        guard let event else { return nil }
        switch event {
        case .spatialLeft:  return .left
        case .spatialRight: return .right
        case .prevRow:      return .up
        case .nextRow:      return .down
        default:            return nil
        }
    }

    @Test func leftArrowMirror_h() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "h")) == .left)
    }

    @Test func rightArrowMirror_l() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "l")) == .right)
    }

    @Test func upArrowMirror_k() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "k")) == .up)
    }

    @Test func downArrowMirror_j() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "j")) == .down)
    }

    /// Everything else has to fall through so the existing panel-action and
    /// letter-jump branches still get their shot. Uppercase counts too — the
    /// tap lowercases before consulting the mapping, and the helper itself
    /// stays case-sensitive so a stray capital can't trigger nav.
    @Test func nonVimKeysReturnNil() {
        for character: Character in ["a", "g", "i", "m", "q", "w", "z",
                                     "0", "9", " ", "/", "\\", "\n",
                                     "H", "J", "K", "L"] {
            #expect(HotkeyTap.vimNavigationEvent(for: character) == nil,
                    "\(character) should not be a vim navigation key")
        }
    }
}
