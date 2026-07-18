import Foundation
import Testing
@testable import BetterCmdTab

@Suite("AppCatalogCache recovery")
struct AppCatalogCacheRecoveryTests {

    // MARK: - Broken-cache detection (the "⌘Tab opens empty" rescue trigger)

    @Test("empty cache after a completed scan with apps running is broken")
    func emptyAfterScanWithAppsIsBroken() {
        #expect(AppCatalogCache.cacheLooksBroken(
            hasCompletedFullScan: true,
            isEmpty: true,
            hasRunningRegularApp: true))
    }

    @Test("a cold cache (no scan yet) is never treated as broken")
    func coldCacheIsNotBroken() {
        // Before the first scan, emptiness is expected — the placeholder path
        // handles it, so the rescan must not fire here.
        #expect(!AppCatalogCache.cacheLooksBroken(
            hasCompletedFullScan: false,
            isEmpty: true,
            hasRunningRegularApp: true))
    }

    @Test("a populated cache is never broken, even scanned with apps running")
    func populatedCacheIsNotBroken() {
        #expect(!AppCatalogCache.cacheLooksBroken(
            hasCompletedFullScan: true,
            isEmpty: false,
            hasRunningRegularApp: true))
    }

    @Test("empty cache with no regular apps is legitimately empty, not broken")
    func emptyWithNoAppsIsLegitimate() {
        // The #31 case: filters legitimately hide everything (or nothing is
        // running) — present the empty state without a wasteful rescan.
        #expect(!AppCatalogCache.cacheLooksBroken(
            hasCompletedFullScan: true,
            isEmpty: true,
            hasRunningRegularApp: false))
    }
}
