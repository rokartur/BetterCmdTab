import Carbon.HIToolbox
import Testing
@testable import BetterCmdTab

@Suite("English keyboard mapping")
@MainActor
struct EnglishKeyboardMappingTests {
    @Test("US letters and punctuation resolve without selecting a US input source")
    func englishKeys() throws {
        let layout = try #require(KeyboardLayout.englishLayoutData())
        let keys: [(Int, Character)] = [
            (kVK_ANSI_Q, "q"), (kVK_ANSI_A, "a"), (kVK_ANSI_Z, "z"),
            (kVK_ANSI_C, "c"), (kVK_ANSI_H, "h"), (kVK_ANSI_R, "r"),
            (kVK_ANSI_O, "o"), (kVK_ANSI_M, "m"), (kVK_ANSI_E, "e"),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"),
            (kVK_ANSI_1, "1"), (kVK_ANSI_Semicolon, ";"),
        ]
        for (key, expected) in keys {
            #expect(KeyboardLayout.translate( UInt16(key), in: layout) == expected)
        }
    }

    @Test("Search preserves US Shift and Option modifiers")
    func modifiedSearchKeys() throws {
        let layout = try #require(KeyboardLayout.englishLayoutData())
        let shift = HotkeyTap.carbonModifierKeyState(shift: true, option: false)
        #expect(KeyboardLayout.translate( UInt16(kVK_ANSI_A), in: layout, modifiers: shift) == "A")
        #expect(KeyboardLayout.translate( UInt16(kVK_ANSI_1), in: layout, modifiers: shift) == "!")
        let option = HotkeyTap.carbonModifierKeyState(shift: false, option: true)
        #expect(KeyboardLayout.translate( UInt16(kVK_ANSI_2), in: layout, modifiers: option) == "™")
    }
}
