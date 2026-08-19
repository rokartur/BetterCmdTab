import AppKit
import Testing
@testable import BetterCmdTab

/// Covers the selection color (#185): which concrete color each choice resolves
/// to, and the hex parsing/formatting behind the custom choice — the two places
/// a bad value would silently paint the switcher the wrong color instead of
/// failing loudly.
@Suite("Selection color")
struct SelectionColorTests {

    @Test("fixed choices resolve to their own color, system and custom to the macOS accent")
    func resolvedColors() {
        #expect(SwitcherSelectionColor.blue.resolved == .systemBlue)
        #expect(SwitcherSelectionColor.purple.resolved == .systemPurple)
        #expect(SwitcherSelectionColor.graphite.resolved == .systemGray)
        // `.custom` has no color of its own — the hex lives in Preferences, so
        // resolving it here must fall back rather than invent one.
        #expect(SwitcherSelectionColor.system.resolved == .controlAccentColor)
        #expect(SwitcherSelectionColor.custom.resolved == .controlAccentColor)
        #expect(SwitcherSelectionColor.system.color == nil)
        #expect(SwitcherSelectionColor.custom.color == nil)
    }

    @Test("the stored raw values are stable and every case has a name")
    func rawValuesAndNames() {
        #expect(SwitcherSelectionColor(rawValue: "system") == .system)
        #expect(SwitcherSelectionColor(rawValue: "custom") == .custom)
        #expect(SwitcherSelectionColor(rawValue: "chartreuse") == nil)
        for choice in SwitcherSelectionColor.allCases {
            #expect(!choice.displayName.isEmpty)
        }
    }

    @Test("hex parses with and without the leading hash, in 6 and 8 digits")
    func hexParsing() throws {
        let plain = try #require(NSColor(hexString: "FF8000"))
        let hashed = try #require(NSColor(hexString: "#FF8000"))
        #expect(plain.hexString == "#FF8000")
        #expect(hashed.hexString == "#FF8000")
        // Whitespace survives a paste out of a design tool.
        #expect(NSColor(hexString: "  #ff8000\n")?.hexString == "#FF8000")

        let withAlpha = try #require(NSColor(hexString: "#FF800080"))
        #expect(abs(withAlpha.alphaComponent - 128.0 / 255.0) < 0.001)
        // The 8-digit form keeps its RGB; only the alpha is extra.
        #expect(withAlpha.hexString == "#FF8000")
    }

    @Test("malformed hex is rejected so callers fall back to the accent")
    func hexRejectsGarbage() {
        #expect(NSColor(hexString: "") == nil)
        #expect(NSColor(hexString: "#FFF") == nil)          // 3-digit shorthand isn't supported
        #expect(NSColor(hexString: "#FF80") == nil)
        #expect(NSColor(hexString: "#GGGGGG") == nil)
        #expect(NSColor(hexString: "rebeccapurple") == nil)
    }

    @Test("hex round-trips through the color and back")
    func hexRoundTrip() throws {
        for hex in ["#000000", "#FFFFFF", "#1D9BF0", "#7F3FBF"] {
            let color = try #require(NSColor(hexString: hex))
            #expect(color.hexString == hex)
        }
    }

    @MainActor
    @Test("the selection plate tints the accent without hiding the panel behind it")
    func selectionFillIsTranslucent() {
        let fill = SwitcherIconItemView.selectionFill(.systemPurple)
        #expect(fill.alphaComponent < 1)
        #expect(fill.alphaComponent > 0)
        #expect(fill.usingColorSpace(.sRGB)?.redComponent
                == NSColor.systemPurple.usingColorSpace(.sRGB)?.redComponent)
    }
}
