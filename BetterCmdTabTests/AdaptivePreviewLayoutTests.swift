import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Adaptive preview layout")
struct AdaptivePreviewLayoutTests {
    @Test func windowSizesDriveWidthWithBoundsAndFallback() {
        let sizes: [CGSize?] = [
            CGSize(width: 900, height: 1200),
            CGSize(width: 1200, height: 1200),
            CGSize(width: 2400, height: 1200),
            CGSize(width: 4800, height: 1200),
            .zero,
            nil,
            CGSize(width: CGFloat.infinity, height: .infinity),
        ]
        let ratios = sizes.map { SwitcherView.previewAspectRatio(for: $0) }
        let fit = SwitcherView.fitAdaptivePreviewRows(
            ratios, thumbnailHeight: 130, gap: 12, maxWidth: 300, columnCap: 0
        )
        #expect(fit.widths == [98, 130, 260, 300, 208, 208, 208])
        #expect(fit.rows.map(\.indices) == [0..<2, 2..<3, 3..<4, 4..<5, 5..<6, 6..<7])
        #expect(fit.rows.map(\.width) == [240, 260, 300, 208, 208, 208])
    }

    @Test func ultrawideStopsAtTheClamp() {
        #expect(SwitcherView.previewAspectRatio(for: CGSize(width: 5120, height: 1440)) == 3.2)
        #expect(SwitcherView.previewAspectRatio(for: CGSize(width: 400, height: 1200)) == 0.6)
    }

    @Test func wrapsAtColumnCapEvenWhenMoreTilesFit() {
        let fit = SwitcherView.fitAdaptivePreviewRows(
            [1, 2, 1], thumbnailHeight: 100, gap: 10, maxWidth: 500, columnCap: 2
        )
        #expect(fit.rows.map(\.indices) == [0..<2, 2..<3])
        #expect(fit.rows.map(\.width) == [310, 100])
    }
}
