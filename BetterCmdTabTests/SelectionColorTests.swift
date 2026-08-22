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
        #expect(SwitcherSelectionColor.blue.nsColor(customHex: nil) == .systemBlue)
        #expect(SwitcherSelectionColor.purple.nsColor(customHex: nil) == .systemPurple)
        #expect(SwitcherSelectionColor.graphite.nsColor(customHex: nil) == .systemGray)
        #expect(SwitcherSelectionColor.system.nsColor(customHex: nil) == .controlAccentColor)
        // A fixed choice ignores the hex — only `.custom` reads it.
        #expect(SwitcherSelectionColor.blue.nsColor(customHex: "#FF8000") == .systemBlue)
        #expect(SwitcherSelectionColor.system.color == nil)
        #expect(SwitcherSelectionColor.custom.color == nil)
    }

    /// `.transparent` still tints the quick-jump letters with the accent — only the
    /// selection plate goes neutral. It therefore resolves to the *same color* as
    /// `.system`, which is why `EffectiveSettings.selectionColorKey` carries the
    /// raw value too: without it a pooled tile would not repaint when the user
    /// switches between the two.
    @Test("transparent keeps the accent for letters and stays legible on the list plate")
    func transparentResolution() throws {
        #expect(SwitcherSelectionColor.transparent.color == nil)
        #expect(SwitcherSelectionColor.transparent.nsColor(customHex: nil)
            == SwitcherSelectionColor.system.nsColor(customHex: nil))

        // The list plate is opaque even without a hue, so its labels still flip.
        for (name, want) in [(NSAppearance.Name.aqua, NSColor.black), (.darkAqua, .white)] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let plate = NSColor.unemphasizedSelectedContentBackgroundColor
                #expect(plate.contrastingLabelColor == want, "under \(name.rawValue)")
            }
        }
    }

    @Test("custom takes the stored hex, opaque, and falls back to the accent without one")
    func customResolution() {
        #expect(SwitcherSelectionColor.custom.nsColor(customHex: "#FF8000").hexString == "#FF8000")
        #expect(SwitcherSelectionColor.custom.nsColor(customHex: nil) == .controlAccentColor)
        #expect(SwitcherSelectionColor.custom.nsColor(customHex: "nonsense") == .controlAccentColor)
        // A translucent hex must not leak into the rim, which draws at full alpha.
        #expect(SwitcherSelectionColor.custom.nsColor(customHex: "#FF800000").alphaComponent == 1)
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
        // `UInt64(_:radix:)` accepts a sign prefix on its own, which would turn
        // "+F8000" into 0x0F8000 instead of rejecting it.
        #expect(NSColor(hexString: "+F8000") == nil)
        #expect(NSColor(hexString: "#+F8000") == nil)
        #expect(NSColor(hexString: "-F8000") == nil)
    }

    /// Pins every preset in both appearances, so the luma threshold cannot drift
    /// without a failure. `graphite` (0.558 light / 0.597 dark) and `orange`
    /// (0.619 / 0.636) are the ones that sit closest to the cut — a threshold of
    /// 0.6 put graphite-on-dark on white at 2.9:1.
    @Test("labels on the opaque list plate flip to stay legible on light selections")
    func contrastingLabelColor() throws {
        let expected: [SwitcherSelectionColor: NSColor] = [
            .blue: .white, .purple: .white, .pink: .white, .red: .white,
            .orange: .black, .yellow: .black, .green: .black, .graphite: .black,
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for (choice, want) in expected {
                    let got = choice.nsColor(customHex: nil).contrastingLabelColor
                    #expect(got == want, "\(choice.rawValue) under \(name.rawValue)")
                }
            }
        }
        #expect(NSColor.white.contrastingLabelColor == .black)
        #expect(NSColor.black.contrastingLabelColor == .white)
    }

    @Test("hex round-trips through the color and back")
    func hexRoundTrip() throws {
        for hex in ["#000000", "#FFFFFF", "#1D9BF0", "#7F3FBF"] {
            let color = try #require(NSColor(hexString: hex))
            #expect(color.hexString == hex)
        }
    }

    @MainActor
    @Test("the tinted plate keeps the accent's hue without hiding the panel behind it")
    func selectionPlateTinted() {
        let plate = SwitcherIconItemView.selectionPlate(.systemPurple, neutral: false,
                                                        dark: true, neutralLightFill: 0.30)
        #expect(plate.fill.alphaComponent < 1)
        #expect(plate.fill.alphaComponent > 0)
        #expect(plate.fill.usingColorSpace(.sRGB)?.redComponent
                == NSColor.systemPurple.usingColorSpace(.sRGB)?.redComponent)
        // The rim is the hue at full strength — that is what carries the selection.
        #expect(plate.rim == NSColor.systemPurple)
    }

    /// The neutral plate has no hue to lean on, so it has to lift in dark mode and
    /// sink in light — and it must ignore the color entirely, or `.transparent`
    /// would leak the accent it still hands to the letter hints.
    @MainActor
    @Test("the neutral plate drops the hue and flips direction with the appearance")
    func selectionPlateNeutral() {
        let dark = SwitcherIconItemView.selectionPlate(.systemPurple, neutral: true,
                                                       dark: true, neutralLightFill: 0.30)
        let light = SwitcherIconItemView.selectionPlate(.systemPurple, neutral: true,
                                                        dark: false, neutralLightFill: 0.30)
        #expect(dark.fill.usingColorSpace(.sRGB)?.redComponent == 1)
        #expect(light.fill.usingColorSpace(.sRGB)?.redComponent == 0)
        #expect(dark.rim.usingColorSpace(.sRGB)?.redComponent == 1)
        #expect(light.rim.usingColorSpace(.sRGB)?.redComponent == 0)
        // Window previews keep a lighter fill than the icon grid in light mode.
        let preview = SwitcherIconItemView.selectionPlate(.systemPurple, neutral: true,
                                                          dark: false, neutralLightFill: 0.10)
        #expect(preview.fill.alphaComponent < light.fill.alphaComponent)
    }
}
