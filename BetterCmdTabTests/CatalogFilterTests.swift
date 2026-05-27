import Testing
@testable import BetterCmdTab

@Suite("CatalogFilter")
struct CatalogFilterTests {

    private func config(
        excluded: Set<String> = [],
        pinned: [String] = [],
        showMinimized: Bool = true,
        showHidden: Bool = true,
        showWindowless: Bool = true,
        currentSpaceOnly: Bool = false
    ) -> CatalogFilter.Config {
        CatalogFilter.Config(excluded: excluded, pinned: pinned, showMinimized: showMinimized, showHidden: showHidden, showWindowless: showWindowless, currentSpaceOnly: currentSpaceOnly)
    }

    // MARK: - isIdentity

    @Test("identity config short-circuits filtering")
    func identity() {
        #expect(config().isIdentity)
        #expect(!config(excluded: ["a"]).isIdentity)
        #expect(!config(pinned: ["a"]).isIdentity)
        #expect(!config(showMinimized: false).isIdentity)
        #expect(!config(showHidden: false).isIdentity)
        #expect(!config(showWindowless: false).isIdentity)
    }

    // MARK: - includes

    @Test("permissive config keeps minimized and hidden rows")
    func permissiveKeepsAll() {
        let cfg = config()
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: true, appHidden: true, cfg))
    }

    @Test("excluded bundle id is dropped")
    func exclusion() {
        let cfg = config(excluded: ["com.x"])
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.y", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("placeholders are always kept, even when excluded")
    func placeholderKept() {
        let cfg = config(excluded: ["com.x"], showMinimized: false, showHidden: false)
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: true, isMinimized: true, appHidden: true, cfg))
    }

    @Test("minimized windows dropped when disabled")
    func minimizedToggle() {
        let cfg = config(showMinimized: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: true, appHidden: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("hidden apps dropped when disabled")
    func hiddenToggle() {
        let cfg = config(showHidden: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: true, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("windowless apps dropped when disabled")
    func windowlessToggle() {
        let cfg = config(showWindowless: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, hasWindow: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, hasWindow: true, cfg))
        // Placeholders survive even with no window.
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: true, isMinimized: false, appHidden: false, hasWindow: false, cfg))
    }

    // MARK: - stablePartition (pin reordering)

    @Test("no pins preserves original order")
    func noPins() {
        let result = CatalogFilter.stablePartition([1, 2, 3, 4]) { _ in nil }
        #expect(result == [1, 2, 3, 4])
    }

    @Test("pinned items move to front ordered by rank")
    func pinnedByRank() {
        let ranks = ["30": 0, "10": 1]
        let result = CatalogFilter.stablePartition([10, 20, 30, 40]) { ranks[String($0)] }
        #expect(result == [30, 10, 20, 40])
    }

    @Test("same-rank pinned items keep original order (stable)")
    func stableWithinRank() {
        // Even values share rank 0; odd values are not pinned.
        let result = CatalogFilter.stablePartition([1, 2, 3, 4, 5]) { $0 % 2 == 0 ? 0 : nil }
        #expect(result == [2, 4, 1, 3, 5])
    }
}
