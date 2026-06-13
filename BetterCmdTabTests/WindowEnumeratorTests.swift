import CoreGraphics
import Foundation
import Testing
@testable import BetterCmdTab

@Suite("WindowEnumerator")
struct WindowEnumeratorTests {

    // MARK: - cgWindowBucket

    @Test("layer 0, opaque, large enough -> normal")
    func normalWindow() {
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 200, height: 200) == .normal)
    }

    @Test("Dock-level-and-above overlays -> nonNormalLayer (the notification phantom)")
    func notificationPhantom() {
        // Teams Notification Center "Window": level 20 (Dock); a second helper at 103.
        #expect(WindowEnumerator.cgWindowBucket(layer: 20, alpha: 1.0, width: 200, height: 200) == .nonNormalLayer)
        #expect(WindowEnumerator.cgWindowBucket(layer: 103, alpha: 1.0, width: 200, height: 200) == .nonNormalLayer)
    }

    @Test("floating / modal / utility windows (levels 1-19) stay switchable")
    func keepBandWindows() {
        // "Float on top" document window, modal panel, utility panel — real,
        // user-reachable windows that must NOT be dropped.
        #expect(WindowEnumerator.cgWindowBucket(layer: 3, alpha: 1.0, width: 200, height: 200) == .normal)
        #expect(WindowEnumerator.cgWindowBucket(layer: 8, alpha: 1.0, width: 200, height: 200) == .normal)
        #expect(WindowEnumerator.cgWindowBucket(layer: 19, alpha: 1.0, width: 200, height: 200) == .normal)
    }

    @Test("sub-normal desktop band -> nonNormalLayer")
    func desktopBand() {
        #expect(WindowEnumerator.cgWindowBucket(layer: -1, alpha: 1.0, width: 360, height: 360) == .nonNormalLayer)
    }

    @Test("Dock level is the drop floor; one below stays")
    func dropFloorBoundary() {
        let floor = WindowEnumerator.dockWindowLevel
        #expect(WindowEnumerator.cgWindowBucket(layer: floor, alpha: 1.0, width: 200, height: 200) == .nonNormalLayer)
        #expect(WindowEnumerator.cgWindowBucket(layer: floor - 1, alpha: 1.0, width: 200, height: 200) == .normal)
    }

    @Test("layer 0 but invisible or sub-100px -> excluded")
    func excludedWindow() {
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 0.0, width: 200, height: 200) == .excluded)
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 50, height: 50) == .excluded)
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 200, height: 50) == .excluded)
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 50, height: 200) == .excluded)
    }

    @Test("non-switchable layer takes precedence over alpha/size")
    func layerPrecedence() {
        #expect(WindowEnumerator.cgWindowBucket(layer: 20, alpha: 0.0, width: 50, height: 50) == .nonNormalLayer)
    }
}
