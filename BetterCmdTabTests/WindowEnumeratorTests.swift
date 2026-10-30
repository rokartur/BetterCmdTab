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

    @Test("missing bounds defaults to large enough -> normal")
    func missingBoundsKept() {
        // snapshotCGWindowMap defaults an absent bounds key to greatestFiniteMagnitude
        // so a window with no bounds is kept (the prior "no bounds -> keep" behavior).
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude) == .normal)
    }

    @Test("present-but-empty bounds (0x0) -> excluded")
    func emptyBoundsExcluded() {
        // A bounds dict missing Width/Height yields 0, which the size gate excludes.
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 0, height: 0) == .excluded)
    }

    @Test("Stage Manager: strip-tile sized windows stay normal (#116)")
    func stageManagerKeepsStripTiles() {
        // Measured on macOS 26: an off-stage window is reported at ~83×103.
        // With Stage Manager off that is a junk surface; with it on it is a real
        // user window and must stay in the CG hint / on-screen set.
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 83, height: 103) == .excluded)
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 1.0, width: 83, height: 103, stageManager: true) == .normal)
    }

    @Test("Stage Manager does not re-admit invisible or overlay windows")
    func stageManagerKeepsOtherGates() {
        #expect(WindowEnumerator.cgWindowBucket(layer: 0, alpha: 0.0, width: 83, height: 103, stageManager: true) == .excluded)
        #expect(WindowEnumerator.cgWindowBucket(layer: 20, alpha: 1.0, width: 83, height: 103, stageManager: true) == .nonNormalLayer)
    }

    // MARK: - snapshot z-order

    private func entry(wid: Int, layer: Int = 0, onscreen: Bool = true) -> NSDictionary {
        [
            kCGWindowOwnerPID as String: 1,
            kCGWindowNumber as String: wid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["Width": 800.0, "Height": 600.0],
            kCGWindowIsOnscreen as String: onscreen,
        ] as NSDictionary
    }

    @Test("z-order follows the on-screen list, not the .optionAll list")
    func zOrderFromOnscreenList() {
        // Measured on macOS 27.2: after window 1 is raised, `.optionAll` still lists
        // creation order while the on-screen list has 1 in front.
        let all = [entry(wid: 4, onscreen: false), entry(wid: 3), entry(wid: 2), entry(wid: 1), entry(wid: 9, layer: 25)]
        let onscreen = [entry(wid: 9, layer: 25), entry(wid: 1), entry(wid: 3), entry(wid: 2)]
        let snapshot = WindowEnumerator.snapshot(all: all, onscreenFrontToBack: onscreen, stageManager: false)
        #expect(snapshot.zOrder(for: 1) == [1, 3, 2])
        #expect(snapshot.ids(for: 1) == [1, 2, 3, 4])
    }
}
