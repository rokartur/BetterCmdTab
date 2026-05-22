import AppKit

struct SwitcherMetrics: Equatable {
    let scale: CGFloat
    let rowHeight: CGFloat
    let rowWidth: CGFloat
    let iconSize: CGFloat
    let appNameWidth: CGFloat
    let interGap: CGFloat
    let horizontalInset: CGFloat
    let fontSize: CGFloat
    let outerPadding: CGFloat
    let cornerRadius: CGFloat
    let highlightCornerRadius: CGFloat
    let highlightInset: CGFloat
    let labelHeight: CGFloat
    let letterColumnWidth: CGFloat
    let letterFontSize: CGFloat

    static let baseRowHeight: CGFloat = 28
    static let baseRowWidth: CGFloat = 720
    static let baseIconSize: CGFloat = 18
    static let baseAppNameWidth: CGFloat = 200
    static let baseInterGap: CGFloat = 10
    static let baseHorizontalInset: CGFloat = 14
    static let baseFontSize: CGFloat = 13
    static let baseOuterPadding: CGFloat = 8
    static let baseCornerRadius: CGFloat = 12
    static let baseHighlightCornerRadius: CGFloat = 6
    static let baseHighlightInset: CGFloat = 4
    static let baseLabelHeight: CGFloat = 18
    static let baseLetterColumnWidth: CGFloat = 34
    static let baseLetterFontSize: CGFloat = 11
    static let referenceWidth: CGFloat = 1440

    static let baseline = SwitcherMetrics.forScale(1.0)

    static func forScreen(_ screen: NSScreen?) -> SwitcherMetrics {
        let width = screen?.frame.width ?? referenceWidth
        let raw = width / referenceWidth
        let clamped = max(1.0, min(1.8, raw))
        return forScale(clamped)
    }

    static func forScale(_ scale: CGFloat) -> SwitcherMetrics {
        SwitcherMetrics(
            scale: scale,
            rowHeight: round(baseRowHeight * scale),
            rowWidth: round(baseRowWidth * scale),
            iconSize: round(baseIconSize * scale),
            appNameWidth: round(baseAppNameWidth * scale),
            interGap: round(baseInterGap * scale),
            horizontalInset: round(baseHorizontalInset * scale),
            fontSize: baseFontSize * scale,
            outerPadding: round(baseOuterPadding * scale),
            cornerRadius: round(baseCornerRadius * scale),
            highlightCornerRadius: round(baseHighlightCornerRadius * scale),
            highlightInset: round(baseHighlightInset * scale),
            labelHeight: round(baseLabelHeight * scale),
            letterColumnWidth: round(baseLetterColumnWidth * scale),
            letterFontSize: baseLetterFontSize * scale
        )
    }
}
