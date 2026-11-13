import Testing
import CoreGraphics
@testable import BetterCmdTab

/// Native macOS window tabs surface as several NSWindows at one frame. On
/// current macOS AppKit lists only the front tab and the brute scan recovers
/// the rest; some apps leave a background tab's frame at its stale pre-merge
/// cascade offset (CotEditor, issue #81), and older macOS (Sonoma) AX-lists
/// every tab window. These cover `resolveTabStacks`, the pure rule that
/// decides which windows are background tabs to fold (collapse) or flag
/// (expand) vs. genuinely separate windows to keep, and
/// `tabSpaceQueryIndices`, the gate that bounds the per-window Space IPCs to
/// the tab-shaped groups.
@Suite("Tab stack resolution")
struct TabStackResolutionTests {

    /// The tab group's on-screen frame, a stale pre-merge cascade offset of it
    /// (21pt, what CotEditor leaves on background tabs), and an unrelated frame.
    private let F = CGRect(x: 720, y: 319, width: 640, height: 720)
    private let Fstale = CGRect(x: 741, y: 320, width: 640, height: 720)
    private let G = CGRect(x: 100, y: 100, width: 800, height: 600)

    /// Convenience: everything AX-listed defaults to on screen; brute-only
    /// windows default to off screen. Override per test.
    private func resolve(
        frames: [CGRect?],
        fromAXList: [Bool],
        onscreen: [Bool]? = nil,
        spaceless: [Bool]? = nil,
        onSpace: [Bool]? = nil,
        expand: Bool,
        stageManager: Bool = false
    ) -> WindowEnumerator.TabResolution {
        WindowEnumerator.resolveTabStacks(
            frames: frames,
            fromAXList: fromAXList,
            onscreen: onscreen ?? fromAXList,
            spaceless: spaceless ?? [Bool](repeating: false, count: frames.count),
            onSpace: onSpace ?? [Bool](repeating: false, count: frames.count),
            expand: expand,
            stageManager: stageManager
        )
    }

    // MARK: - Stage Manager (#116)

    /// Measured on macOS 26 with Stage Manager on ("show windows one at a
    /// time"): seven TextEdit windows, identical 586×488, cascaded 15pt apart,
    /// one on stage and the rest ordered out. Every off-stage window sits inside
    /// `tabFrameTolerance` of the staged one, so the near-frame rule folds four
    /// real windows away and the switcher shows 3 rows instead of 7.
    private var stageManagerCascade: (frames: [CGRect?], onscreen: [Bool]) {
        let frames: [CGRect?] = (0..<7).map {
            CGRect(x: 400 + CGFloat($0) * 15, y: 200 + CGFloat($0) * 15, width: 586, height: 488)
        }
        // Index 1 is on stage; the rest report their strip tile and are ordered out.
        return (frames, [false, true, false, false, false, false, false])
    }

    @Test("Stage Manager: cascaded windows are not folded as tab siblings")
    func stageManagerKeepsCascadedWindows() {
        let (frames, onscreen) = stageManagerCascade
        let r = resolve(
            frames: frames,
            fromAXList: [Bool](repeating: true, count: 7),
            onscreen: onscreen,
            spaceless: [Bool](repeating: true, count: 7),
            expand: false,
            stageManager: true
        )
        #expect(r.keep == [Bool](repeating: true, count: 7))
        #expect(r.siblingIndices.isEmpty)
    }

    /// Guards the flag itself: without it the same input loses four windows,
    /// which is exactly the bug. Documents why the gate has to exist.
    @Test("without the Stage Manager flag the same cascade loses four windows")
    func cascadeWouldFoldWithoutStageManagerFlag() {
        let (frames, onscreen) = stageManagerCascade
        let r = resolve(
            frames: frames,
            fromAXList: [Bool](repeating: true, count: 7),
            onscreen: onscreen,
            spaceless: [Bool](repeating: true, count: 7),
            expand: false,
            stageManager: false
        )
        #expect(r.keep.filter { $0 }.count == 3)
    }

    @Test("Stage Manager still collapses ordinary native tab groups")
    func stageManagerKeepsExactFrameTabCollapse() {
        // Exact-frame brute-only rule is untouched: front tab + 2 background
        // tabs at the identical group frame still fold into one row.
        let r = resolve(
            frames: [F, F, F],
            fromAXList: [true, false, false],
            expand: false,
            stageManager: true
        )
        #expect(r.keep == [true, false, false])
        #expect(r.siblingIndices[0] == [1, 2])
    }

    @Test("expand keeps every window as its own row and flags background tabs")
    func expandKeepsAll() {
        let r = resolve(
            frames: [F, F, F],
            fromAXList: [true, false, false],
            expand: true
        )
        #expect(r.keep == [true, true, true])
        #expect(r.siblingIndices.isEmpty)
        // The brute-only siblings are tab rows — the flag that exempts them
        // from the phantom-window filter (they are spaceless while tabbed away).
        #expect(r.tabSibling == [false, true, true])
    }

    @Test("collapse folds brute-only siblings into the AX-listed front tab")
    func collapseFoldsBackgroundTabs() {
        // Ghostty/TextEdit shape: 1 front (AX-listed) + 2 background tabs
        // (brute) at the exact group frame. No Space data needed.
        let r = resolve(
            frames: [F, F, F],
            fromAXList: [true, false, false],
            expand: false
        )
        #expect(r.keep == [true, false, false])
        #expect(r.siblingIndices[0] == [1, 2])
        #expect(r.tabSibling == [false, false, false])
    }

    @Test("collapse never merges two real overlapping windows (issue #10)")
    func collapseKeepsTwoAXListedWindows() {
        // Two maximized Chrome windows: both in the AX list, both ordered in,
        // same frame, NOT tabs.
        let r = resolve(
            frames: [F, F],
            fromAXList: [true, true],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("collapse folds a spaceless background tab left at a stale cascade frame (issue #81)")
    func collapseFoldsStaleFrameTab() {
        // The CotEditor shape: background tabs are brute-only but keep their
        // pre-merge frame (~21pt off the group's), so the exact rule misses
        // them. They are ordered out and spaceless → near-frame rule folds them.
        let r = resolve(
            frames: [F, Fstale, Fstale],
            fromAXList: [true, false, false],
            onscreen: [true, false, false],
            spaceless: [false, true, true],
            expand: false
        )
        #expect(r.keep == [true, false, false])
        #expect(r.siblingIndices[0] == [1, 2])
    }

    @Test("collapse folds an AX-listed spaceless ordered-out tab (Sonoma shape)")
    func collapseFoldsAXListedSpacelessTab() {
        // macOS builds that AX-list every tab window: the front tab is ordered
        // in; the background tabs are ordered out and positively spaceless.
        let r = resolve(
            frames: [F, F, F],
            fromAXList: [true, true, true],
            onscreen: [true, false, false],
            spaceless: [false, true, true],
            expand: false
        )
        #expect(r.keep == [true, false, false])
        #expect(r.siblingIndices[0] == [1, 2])
    }

    @Test("a window mid fullscreen-exit is never folded (issue #148)")
    func fullscreenExitWindowKept() {
        // Measured on macOS 26: for ~50-100ms after leaving full screen the
        // returning window is back in the AX list but still ordered out, at its
        // restored frame — 29pt from a cascaded sibling, inside the tolerance —
        // and WindowServer resolves it to the current Space. Folding it dropped
        // it from the switcher until an unrelated event re-scanned the app.
        let r = resolve(
            frames: [F, Fstale],
            fromAXList: [true, true],
            onscreen: [true, false],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("a stale-frame window beyond the tolerance is never folded")
    func farFrameKept() {
        // Same size but 200pt away: a deliberately placed second window, not a
        // tab — even if WindowServer calls it spaceless.
        let far = CGRect(x: F.origin.x + 200, y: F.origin.y, width: F.width, height: F.height)
        let r = resolve(
            frames: [F, far],
            fromAXList: [true, false],
            onscreen: [true, false],
            spaceless: [false, true],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("collapse folds a spaceless background tab whose size drifted 1pt (Ghostty)")
    func collapseFoldsSizeDriftTab() {
        let drifted = CGRect(x: F.origin.x, y: F.origin.y, width: F.width, height: F.height - 1)
        let r = resolve(
            frames: [F, F, drifted],
            fromAXList: [true, false, false],
            onscreen: [true, false, false],
            spaceless: [false, true, true],
            expand: false
        )
        #expect(r.keep == [true, false, false])
        #expect(r.siblingIndices[0] == [1, 2])
    }

    @Test("a near-frame window with a different size is never folded")
    func differentSizeKept() {
        let resized = CGRect(x: F.origin.x + 10, y: F.origin.y, width: F.width + 100, height: F.height)
        let r = resolve(
            frames: [F, resized],
            fromAXList: [true, false],
            onscreen: [true, false],
            spaceless: [false, true],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("spaceless windows are not folded without a front")
    func spacelessGroupWithoutFrontNotFolded() {
        // Every window ordered out and none resolves to a Space, so there is no
        // front to fold under and the near rule keeps all.
        let r = resolve(
            frames: [F, Fstale],
            fromAXList: [true, true],
            onscreen: [false, false],
            spaceless: [true, true],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    /// Measured on macOS 27.2 with Ghostty's tab group on the desktop and another
    /// app's full-screen Space active (issue #301): the AX list is empty, nothing
    /// is on screen, only the front tab resolves to a Space.
    @Test("collapse folds the tabs of an app on another Space (issue #301)")
    func collapseFoldsTabsOnAnotherSpace() {
        let r = resolve(
            frames: [F, F, F],
            fromAXList: [false, false, false],
            onscreen: [false, false, false],
            spaceless: [true, false, true],
            onSpace: [false, true, false],
            expand: false
        )
        #expect(r.keep == [false, true, false])
        #expect(r.siblingIndices[1] == [0, 2])
    }

    @Test("two real windows on another Space are never folded")
    func twoWindowsOnAnotherSpaceKept() {
        let r = resolve(
            frames: [F, Fstale],
            fromAXList: [false, false],
            onscreen: [false, false],
            onSpace: [true, true],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("expand flags stale-frame and AX-listed tabs too (issue #81)")
    func expandFlagsNearFrameTabs() {
        let r = resolve(
            frames: [F, Fstale, F],
            fromAXList: [true, false, true],
            onscreen: [true, false, false],
            spaceless: [false, true, true],
            expand: true
        )
        #expect(r.keep == [true, true, true])
        #expect(r.tabSibling == [false, true, true])
    }

    @Test("siblings fold under the ordered-in front tab, not the first AX-listed window")
    func frontPickPrefersOrderedIn() {
        // AX list order is arbitrary — index 0 is a tabbed-away window listed
        // before the visible front tab (index 1). The fold must anchor on the
        // ordered-in window.
        let r = resolve(
            frames: [F, F, F],
            fromAXList: [true, true, false],
            onscreen: [false, true, false],
            spaceless: [true, false, false],
            expand: false
        )
        #expect(r.keep == [false, true, false])
        #expect(r.siblingIndices[1] == [0, 2])
    }

    @Test("collapse keeps brute-only windows whose frame has no AX-listed window")
    func collapseKeepsLoneBruteWindow() {
        // e.g. a fullscreen window the public list misses — keep it (prior behavior).
        let r = resolve(
            frames: [G],
            fromAXList: [false],
            expand: false
        )
        #expect(r.keep == [true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("collapse handles a tab group alongside a separate window")
    func collapseMixed() {
        // [front F (ax), bg F (brute), bg F (brute), other G (ax)]
        let r = resolve(
            frames: [F, F, F, G],
            fromAXList: [true, false, false, true],
            expand: false
        )
        #expect(r.keep == [true, false, false, true])
        #expect(r.siblingIndices[0] == [1, 2])
        #expect(r.siblingIndices[3] == nil)   // the separate window has no siblings
    }

    @Test("a nil frame (minimized/unframeable) is never treated as a tab")
    func nilFrameNotTab() {
        let r = resolve(
            frames: [nil, nil],
            fromAXList: [true, false],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    @Test("a brute-only nil-frame window (fullscreen) is kept even next to an AX window with a real frame")
    func fullscreenNilFrameKept() {
        // The caller maps fullscreen (and minimized) windows to a nil frame,
        // so two separate fullscreen windows of one app — one AX-listed on the
        // current Space, one recovered off-Space by the brute scan — are never
        // folded into one row (issue #10 / off-Space fullscreen vanish). Here the
        // brute window's nil frame must not collapse despite an AX window present.
        let r = resolve(
            frames: [F, nil],
            fromAXList: [true, false],
            expand: false
        )
        #expect(r.keep == [true, true])
        #expect(r.siblingIndices.isEmpty)
    }

    // MARK: - tabSpaceQueryIndices (Space-IPC gate)

    @Test("no Space query for the common shape (brute tabs at the exact group frame)")
    func noQueryForExactBruteTabs() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, F, F],
            fromAXList: [true, false, false],
            onscreen: [true, false, false]
        )
        #expect(indices.isEmpty)
    }

    @Test("no Space query when every window is ordered in")
    func noQueryWhenAllOnscreen() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, F],
            fromAXList: [true, true],
            onscreen: [true, true]
        )
        #expect(indices.isEmpty)
    }

    @Test("Space query covers stale-frame brute candidates only")
    func queryCoversStaleFrameCandidates() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, Fstale, Fstale, G],
            fromAXList: [true, false, false, true],
            onscreen: [true, false, false, true]
        )
        #expect(indices == [1, 2])
    }

    @Test("Space query covers ordered-out AX-listed candidates only")
    func queryCoversAXListedCandidates() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, F, F, G],
            fromAXList: [true, true, true, true],
            onscreen: [true, false, false, true]
        )
        #expect(indices == [1, 2])
    }

    @Test("Space query covers a hidden app's tab group")
    func queryCoversHiddenApp() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, F],
            fromAXList: [true, true],
            onscreen: [false, false]
        )
        #expect(indices == [0, 1])
    }

    @Test("Space query covers a tab group on another Space")
    func queryCoversGroupOnAnotherSpace() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, F, F, G],
            fromAXList: [false, false, false, false],
            onscreen: [false, false, false, false]
        )
        #expect(indices == [0, 1, 2])
    }

    @Test("no Space query for an ordered-out window far from any front")
    func noQueryForFarWindow() {
        let indices = WindowEnumerator.tabSpaceQueryIndices(
            frames: [F, G],
            fromAXList: [true, false],
            onscreen: [true, false]
        )
        #expect(indices.isEmpty)
    }
}
