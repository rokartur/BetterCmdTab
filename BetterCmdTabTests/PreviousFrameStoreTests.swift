import CoreGraphics
import Testing
import BetterShortcuts
@testable import BetterCmdTab

/// Pure-state coverage for the "restore previous window size" store (⌃⌘⌫) and its
/// shortcut registration. The AX frame read/write is impure and exercised
/// manually; the save/restore bookkeeping is isolated here.
@MainActor
@Suite("Previous-frame store")
struct PreviousFrameStoreTests {
    private func clean() { PreviousFrameStore.reset() }

    @Test func saveThenReadRoundtrips() {
        clean()
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        PreviousFrameStore.save(windowId: 42, cocoaRect: rect, wasFullscreen: true)
        #expect(PreviousFrameStore.saved(for: 42) == PreviousFrameStore.Saved(cocoaRect: rect, wasFullscreen: true))
    }

    @Test func unknownWindowIsNil() {
        clean()
        #expect(PreviousFrameStore.saved(for: 999) == nil)
    }

    /// `windowId == 0` means the CGWindowID couldn't be resolved — never store it,
    /// so two unidentifiable windows can't inherit each other's saved frame.
    @Test func zeroWindowIdIgnored() {
        clean()
        PreviousFrameStore.save(windowId: 0, cocoaRect: .init(x: 1, y: 2, width: 3, height: 4), wasFullscreen: false)
        #expect(PreviousFrameStore.saved(for: 0) == nil)
    }

    @Test func saveOverwritesPreviousSnapshot() {
        clean()
        PreviousFrameStore.save(windowId: 7, cocoaRect: .init(x: 0, y: 0, width: 1, height: 1), wasFullscreen: false)
        let newer = CGRect(x: 5, y: 5, width: 50, height: 60)
        PreviousFrameStore.save(windowId: 7, cocoaRect: newer, wasFullscreen: false)
        #expect(PreviousFrameStore.saved(for: 7)?.cocoaRect == newer)
    }

    /// The table is bounded; even after overflowing it, the most-recently saved
    /// window is still restorable.
    @Test func boundedButKeepsLatest() {
        clean()
        let total = PreviousFrameStore.maxEntries + 10
        for i in 1...total {
            PreviousFrameStore.save(windowId: CGWindowID(i), cocoaRect: .init(x: CGFloat(i), y: 0, width: 100, height: 100), wasFullscreen: false)
        }
        #expect(PreviousFrameStore.saved(for: CGWindowID(total)) != nil)
    }

    @Test func restoreShortcutRegistered() {
        #expect(BetterShortcuts.Name.windowMgmt.contains { $0.name == .windowRestorePrevious })
        #expect(BetterShortcuts.Name.allCases.contains(.windowRestorePrevious))
    }
}
