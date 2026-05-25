import AppKit

/// Sizing for the round count badge so it stays a fixed-diameter circle (never
/// a pill, never oversized): the font shrinks to fit longer counts like "134".
@MainActor
enum BadgeText {
    /// Size of a count badge: a circle (width == height) for short counts that
    /// widens into a fixed-height pill once the text needs more room than the
    /// height (i.e. 3+ digits). The font is never shrunk.
    static func size(for text: String, font: NSFont, height: CGFloat) -> NSSize {
        let textW = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        // Small horizontal padding keeps 1–2 digit counts circular; longer
        // counts push the width past the height and form a pill.
        let width = max(height, textW + height * 0.3)
        return NSSize(width: width, height: height)
    }

    /// Full-width frame (so the label's own centered alignment handles
    /// horizontal centering without clipping the last digit) with font-metric
    /// vertical centering inside the badge's height.
    static func centeredTextFrame(width: CGFloat, height: CGFloat, font: NSFont) -> NSRect {
        let lineH = ceil(font.ascender - font.descender)
        return NSRect(x: 0, y: round((height - lineH) / 2), width: width, height: lineH)
    }
}

/// Single source of truth for the small status/indicator glyphs the switcher
/// overlays on rows (list view) and tiles (grid view). Centralizing the symbol
/// names, ordering, and tint roles here keeps the two layouts visually
/// consistent — same icons, same colors, same meaning everywhere.
enum SwitcherIndicator: CaseIterable {
    case audio       // app is playing sound
    case launch      // not-yet-running app, offered for launch
    case reopen      // recently closed, offered for reopen
    case hidden      // app is hidden (⌘H)
    case minimized   // window is minimized
    case noWindow    // running app with no open window
    case fullscreen  // window is full-screen

    /// SF Symbol name. Filled variants are used where available so the glyphs
    /// read as one consistent solid set across both views.
    var symbolName: String {
        switch self {
        case .audio: return "speaker.wave.2.fill"
        case .launch: return "arrow.up.forward.app.fill"
        case .reopen: return "clock.arrow.circlepath"
        case .hidden: return "eye.slash.fill"
        case .minimized: return "minus.rectangle.fill"
        case .noWindow: return "square.dashed"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .audio: return "Playing audio"
        case .launch: return "Launch app"
        case .reopen: return "Reopen recently closed"
        case .hidden: return "Hidden app"
        case .minimized: return "Minimized window"
        case .noWindow: return "No open window"
        case .fullscreen: return "Full-screen window"
        }
    }

    func makeImage() -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
    }

    /// Tint for this indicator. `onAccentFill` is true when the row's selection
    /// paints an accent-colored background *behind* the glyph (list selection),
    /// in which case every glyph turns white to stay legible. Grid selection
    /// uses a neutral translucent backdrop, so it passes false and glyphs keep
    /// their semantic color in every state.
    ///
    /// Semantic colors: audio is green (a distinct "making sound" cue),
    /// launch/reopen use the accent (they're actionable, not just status), and
    /// the window-state glyphs are neutral secondary.
    func tint(onAccentFill: Bool, accent: NSColor) -> NSColor {
        if onAccentFill { return NSColor.white.withAlphaComponent(0.9) }
        switch self {
        case .audio: return .systemGreen
        case .launch, .reopen: return accent
        case .hidden, .minimized, .noWindow, .fullscreen: return .secondaryLabelColor
        }
    }
}
