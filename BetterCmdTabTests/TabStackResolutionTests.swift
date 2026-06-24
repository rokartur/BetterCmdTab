import Testing
@testable import BetterCmdTab

/// Native macOS window tabs surface as several NSWindows at one frame, but
/// AppKit lists only the front tab; the brute scan recovers the rest. These
/// cover `resolveTabStacks`, the pure rule that decides which are background
/// tabs to fold (collapse) vs. genuinely separate windows to keep.
@Suite("Tab stack resolution")
struct TabStackResolutionTests {

    @Test("expand keeps every window as its own row")
    func expandKeepsAll() {
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: ["F", "F", "F"],
            fromAXList: [true, false, false],
            expand: true
        )
        #expect(r.keep == [true, true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("collapse folds brute-only siblings into the AX-listed front tab")
    func collapseFoldsBackgroundTabs() {
        // Ghostty/TextEdit shape: 1 front (AX-listed) + 2 background tabs (brute).
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: ["F", "F", "F"],
            fromAXList: [true, false, false],
            expand: false
        )
        #expect(r.keep == [true, false, false])
        #expect(r.siblingIndices[0] == [1, 2])
    }

    @Test("collapse never merges two real overlapping windows (issue #10)")
    func collapseKeepsTwoAXListedWindows() {
        // Two maximized Chrome windows: both in the AX list, same frame, NOT tabs.
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: ["F", "F"],
            fromAXList: [true, true],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("collapse keeps brute-only windows whose frame has no AX-listed window")
    func collapseKeepsLoneBruteWindow() {
        // e.g. a fullscreen window the public list misses — keep it (prior behavior).
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: ["G"],
            fromAXList: [false],
            expand: false
        )
        #expect(r.keep == [true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("collapse handles a tab group alongside a separate window")
    func collapseMixed() {
        // [front F (ax), bg F (brute), bg F (brute), other G (ax)]
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: ["F", "F", "F", "G"],
            fromAXList: [true, false, false, true],
            expand: false
        )
        #expect(r.keep == [true, false, false, true])
        #expect(r.siblingIndices[0] == [1, 2])
        #expect(r.siblingIndices[3] == nil)   // the separate window has no siblings
    }

    @Test("a nil frame (minimized/unframeable) is never treated as a tab")
    func nilFrameNotTab() {
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: [nil, nil],
            fromAXList: [true, false],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("a brute-only nil-frame window (fullscreen) is kept even next to an AX window with a real frame")
    func fullscreenNilFrameKept() {
        // The caller maps fullscreen (and minimized) windows to a nil frameKey,
        // so two separate fullscreen windows of one app — one AX-listed on the
        // current Space, one recovered off-Space by the brute scan — are never
        // folded into one row (issue #10 / off-Space fullscreen vanish). Here the
        // brute window's nil frame must not collapse despite an AX window present.
        let r = WindowEnumerator.resolveTabStacks(
            frameKeys: ["F", nil],
            fromAXList: [true, false],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }
}

/// `switchableWindowIndices` decides which of an app's windows reach the
/// switcher: every window for a regular app, only user-closable (real) windows
/// for a menu-bar agent, so an agent's non-closable helper window is dropped
/// (issue #43).
@Suite("Agent helper-window filter")
struct SwitchableWindowIndicesTests {

    @Test("regular app surfaces every window, closable or not")
    func regularKeepsAll() {
        #expect(WindowEnumerator.switchableWindowIndices(isRegular: true, hasCloseButton: [true, false, true]) == [0, 1, 2])
    }

    @Test("accessory app keeps only its closable windows")
    func accessoryKeepsClosable() {
        // A menu-bar agent with a real settings window (closable) plus a
        // non-closable status helper → only the real window survives.
        #expect(WindowEnumerator.switchableWindowIndices(isRegular: false, hasCloseButton: [false, true]) == [1])
    }

    @Test("accessory app with no closable window contributes nothing")
    func accessoryAllHelpersDropped() {
        // The MenuBarAgent case: its only window has no close button → dropped.
        #expect(WindowEnumerator.switchableWindowIndices(isRegular: false, hasCloseButton: [false]).isEmpty)
        #expect(WindowEnumerator.switchableWindowIndices(isRegular: false, hasCloseButton: []).isEmpty)
    }

    @Test("accessory app with all-closable windows keeps them all")
    func accessoryKeepsAllClosable() {
        #expect(WindowEnumerator.switchableWindowIndices(isRegular: false, hasCloseButton: [true, true]) == [0, 1])
    }
}
