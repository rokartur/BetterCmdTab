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
}
