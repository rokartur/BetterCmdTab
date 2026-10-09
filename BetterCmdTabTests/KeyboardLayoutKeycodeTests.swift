import Testing
@testable import BetterCmdTab

/// A virtual keycode is a `UInt16`, but it reaches us as whatever wider integer
/// its source hands over — an `Int64` off a CGEvent field, a `UInt32` off a
/// Carbon chord. Any process holding Accessibility can post a synthetic event
/// carrying an out-of-range value, and this runs on every keystroke while the
/// panel is open, so the narrowing has to answer `nil` rather than trap.
@Suite("Keyboard layout keycode narrowing")
struct KeyboardLayoutKeycodeTests {
    /// There is deliberately no positive case: resolving a real character needs
    /// a live keyboard layout, which is not available headlessly. A regression
    /// here traps rather than returning a wrong value, so the run itself is the
    /// assertion.
    @Test("a keycode too wide for UInt16 answers nil instead of trapping",
          arguments: [Int64(UInt16.max) + 1, Int64.max, -1, Int64.min])
    func outOfRangeKeycodeIsNil(_ keyCode: Int64) {
        #expect(KeyboardLayout.character(for: keyCode) == nil)
    }

    @Test("the widest in-range keycode still reaches the layout lookup")
    func maxInRangeKeycodeIsNotRejectedByTheGuard() {
        // UInt16.max is in range for the guard, so this exercises the boundary
        // from the other side: it must not trap on the way to the lookup.
        _ = KeyboardLayout.character(for: Int64(UInt16.max))
    }
}

@Suite("Keyboard layout jump character (#184)")
struct KeyboardLayoutJumpCharacterTests {
    // Russian A, Greek Q, Hebrew Q and Thai H on Apple's layouts, against US.
    @Test("a key typing no ASCII letter reads the ASCII-capable layout's letter",
          arguments: [("ф", "a"), (";", "q"), ("/", "q"), ("\u{0E49}", "h")] as [(Character, Character)])
    func nonLetterKeyReadsLatinLetter(_ typed: Character, _ latin: Character) {
        #expect(KeyboardLayout.jumpCharacter(typed: typed) { latin } == latin)
    }

    @Test("an ASCII letter keeps the active layout's reading", arguments: ["a", "Q"] as [Character])
    func asciiLetterKeepsActiveLayout(_ typed: Character) {
        #expect(KeyboardLayout.jumpCharacter(typed: typed) { "x" } == typed)
    }

    // US /, Russian х against Dvorak, German ö, and a layout with no data.
    @Test("a key that is not an ASCII letter on the ASCII-capable layout keeps the active reading",
          arguments: [("/", "/"), ("х", "/"), ("ö", "ö"), ("ф", nil)] as [(Character, Character?)])
    func nonLetterLatinReadingKeepsActiveLayout(_ typed: Character, _ latin: Character?) {
        #expect(KeyboardLayout.jumpCharacter(typed: typed) { latin } == typed)
    }
}
