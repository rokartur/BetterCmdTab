import AppKit
import Testing
@testable import BetterCmdTab

@Suite("ThumbnailLRU")
struct ThumbnailLRUTests {
    private let image = NSImage(size: NSSize(width: 1, height: 1))
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    @Test("stores and returns an entry with its timestamp")
    func storeAndFetch() {
        var lru = ThumbnailLRU(countLimit: 4, costLimit: 1_000)
        lru.set(image, cost: 10, capturedAt: epoch, for: 7)
        #expect(lru.image(for: 7) === image)
        #expect(lru.capturedAt(for: 7) == epoch)
        #expect(lru.image(for: 8) == nil)
        #expect(lru.capturedAt(for: 8) == nil)
        #expect(lru.count == 1)
        #expect(lru.totalCost == 10)
    }

    @Test("evicts least recently used past the count limit")
    func countEviction() {
        var lru = ThumbnailLRU(countLimit: 2, costLimit: 1_000)
        lru.set(image, cost: 1, capturedAt: epoch, for: 1)
        lru.set(image, cost: 1, capturedAt: epoch, for: 2)
        lru.set(image, cost: 1, capturedAt: epoch, for: 3)
        #expect(lru.image(for: 1) == nil)
        #expect(lru.image(for: 2) != nil)
        #expect(lru.image(for: 3) != nil)
        #expect(lru.count == 2)
    }

    @Test("a read bumps recency so the read entry survives eviction")
    func readBumpsRecency() {
        var lru = ThumbnailLRU(countLimit: 2, costLimit: 1_000)
        lru.set(image, cost: 1, capturedAt: epoch, for: 1)
        lru.set(image, cost: 1, capturedAt: epoch, for: 2)
        _ = lru.image(for: 1)
        lru.set(image, cost: 1, capturedAt: epoch, for: 3)
        #expect(lru.image(for: 1) != nil)
        #expect(lru.image(for: 2) == nil)
        #expect(lru.image(for: 3) != nil)
    }

    @Test("a capturedAt freshness check does not bump recency")
    func timestampReadDoesNotBump() {
        var lru = ThumbnailLRU(countLimit: 2, costLimit: 1_000)
        lru.set(image, cost: 1, capturedAt: epoch, for: 1)
        lru.set(image, cost: 1, capturedAt: epoch, for: 2)
        _ = lru.capturedAt(for: 1)
        lru.set(image, cost: 1, capturedAt: epoch, for: 3)
        #expect(lru.image(for: 1) == nil)
        #expect(lru.image(for: 2) != nil)
    }

    @Test("evicts by total cost")
    func costEviction() {
        var lru = ThumbnailLRU(countLimit: 10, costLimit: 100)
        lru.set(image, cost: 60, capturedAt: epoch, for: 1)
        lru.set(image, cost: 60, capturedAt: epoch, for: 2)
        #expect(lru.image(for: 1) == nil)
        #expect(lru.image(for: 2) != nil)
        #expect(lru.totalCost == 60)
    }

    @Test("an oversized entry survives alone instead of emptying the cache")
    func oversizedEntryKept() {
        var lru = ThumbnailLRU(countLimit: 10, costLimit: 100)
        lru.set(image, cost: 40, capturedAt: epoch, for: 1)
        lru.set(image, cost: 500, capturedAt: epoch, for: 2)
        #expect(lru.image(for: 1) == nil)
        #expect(lru.image(for: 2) != nil)
        #expect(lru.count == 1)
        #expect(lru.totalCost == 500)
    }

    @Test("replacing a key updates cost and timestamp without growing the count")
    func replaceUpdatesCost() {
        var lru = ThumbnailLRU(countLimit: 4, costLimit: 1_000)
        let later = epoch.addingTimeInterval(5)
        lru.set(image, cost: 10, capturedAt: epoch, for: 1)
        lru.set(image, cost: 30, capturedAt: later, for: 1)
        #expect(lru.count == 1)
        #expect(lru.totalCost == 30)
        #expect(lru.capturedAt(for: 1) == later)
    }

    @Test("removeAll resets entries and cost")
    func removeAll() {
        var lru = ThumbnailLRU(countLimit: 4, costLimit: 1_000)
        lru.set(image, cost: 10, capturedAt: epoch, for: 1)
        lru.set(image, cost: 10, capturedAt: epoch, for: 2)
        lru.removeAll()
        #expect(lru.count == 0)
        #expect(lru.totalCost == 0)
        #expect(lru.image(for: 1) == nil)
    }

    @Test("reset invalidates an outstanding thumbnail completion")
    func requestGateRejectsCompletionAfterReset() {
        var gate = ThumbnailRequestGate()
        let token = gate.begin(7)
        #expect(token != nil)
        #expect(gate.count == 1)

        gate.reset()

        #expect(gate.count == 0)
        let acceptedAfterReset = gate.finish(7, token: token!)
        #expect(acceptedAfterReset == false)
    }

    @Test("a stale completion cannot clear a newer request for the same window")
    func requestGateKeepsNewerRequest() {
        var gate = ThumbnailRequestGate()
        let old = gate.begin(9)!
        gate.reset()
        let newer = gate.begin(9)!

        #expect(old != newer)
        let acceptedOld = gate.finish(9, token: old)
        #expect(acceptedOld == false)
        #expect(gate.count == 1)
        let acceptedNewer = gate.finish(9, token: newer)
        #expect(acceptedNewer)
        #expect(gate.count == 0)
    }

    @Test("window and browser-tab thumbnails share limits without key collisions")
    func mixedThumbnailKeysShareBudget() {
        let tab = BrowserTabPreviewKey(pid: 7, windowID: 9, index: 0, pageIdentity: "https://example.test")
        var lru = ThumbnailLRU(countLimit: 2, costLimit: 15)
        lru.set(image, cost: 7, capturedAt: epoch, for: .window(9))
        lru.set(image, cost: 7, capturedAt: epoch, for: .browserTab(tab))
        #expect(lru.count == 2)
        #expect(lru.totalCost == 14)
        let windowImage = lru.image(for: .window(9))
        let tabImage = lru.image(for: .browserTab(tab))
        #expect(windowImage != nil)
        #expect(tabImage != nil)

        lru.set(image, cost: 7, capturedAt: epoch, for: .window(10))
        #expect(lru.count == 2)
        #expect(lru.totalCost == 14)
    }

    @Test("a late browser-tab completion cannot consume a newer tab request")
    func requestGateRejectsLateBrowserCapture() {
        let first = ThumbnailKey.browserTab(.init(pid: 1, windowID: 2, index: 0, pageIdentity: "a"))
        let second = ThumbnailKey.browserTab(.init(pid: 1, windowID: 2, index: 1, pageIdentity: "b"))
        var gate = ThumbnailRequestGate()
        let old = gate.begin(first)!
        let new = gate.begin(second)!
        let acceptedOld = gate.finish(first, token: old)
        #expect(acceptedOld)
        #expect(gate.count == 1)
        let acceptedNew = gate.finish(second, token: new)
        #expect(acceptedNew)
    }

    @Test("static capture retries once only after a transient permitted failure")
    func staticCaptureRetryPolicy() {
        #expect(WindowThumbnailCache.shouldRetryStaticCapture(
            isLive: false, hasScreenRecordingAccess: true, isRetry: false))
        #expect(!WindowThumbnailCache.shouldRetryStaticCapture(
            isLive: false, hasScreenRecordingAccess: false, isRetry: false))
        #expect(!WindowThumbnailCache.shouldRetryStaticCapture(
            isLive: false, hasScreenRecordingAccess: true, isRetry: true))
        #expect(!WindowThumbnailCache.shouldRetryStaticCapture(
            isLive: true, hasScreenRecordingAccess: true, isRetry: false))
    }

    @Test("a browser-tab request cannot approve its own stale key")
    @MainActor func browserCaptureRequiresCurrentTarget() {
        let current = BrowserTabPreviewKey(pid: 1, windowID: 2, index: 0, pageIdentity: "current")
        let stale = BrowserTabPreviewKey(pid: 1, windowID: 2, index: 1, pageIdentity: "stale")
        let cache = WindowThumbnailCache.shared
        cache.setActiveBrowserTab(current)
        #expect(cache.isActiveBrowserTab(current))
        #expect(!cache.isActiveBrowserTab(stale))
        cache.setActiveBrowserTab(nil)
    }
}
