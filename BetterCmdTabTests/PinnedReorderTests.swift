import Testing
@testable import BetterCmdTab

/// The pure array-move behind the pinned-apps drag reorder. `to` is the
/// NSTableView `.above` drop index in pre-removal space, so downward moves shift
/// the destination by one.
@Suite("PinnedReorder")
struct PinnedReorderTests {

    @Test("drop below shifts destination left by one")
    func moveDown() {
        let ids = ["a", "b", "c", "d"]
        // Drag "a" (0) to sit above index 2 (before "c").
        #expect(PinnedReorder.apply(ids, movingRowAt: 0, to: 2) == ["b", "a", "c", "d"])
    }

    @Test("move to bottom")
    func moveToBottom() {
        let ids = ["a", "b", "c"]
        #expect(PinnedReorder.apply(ids, movingRowAt: 0, to: 3) == ["b", "c", "a"])
    }

    @Test("move up to a higher slot")
    func moveUp() {
        let ids = ["a", "b", "c"]
        #expect(PinnedReorder.apply(ids, movingRowAt: 2, to: 0) == ["c", "a", "b"])
    }

    @Test("move to top from the middle")
    func moveToTop() {
        let ids = ["a", "b", "c"]
        #expect(PinnedReorder.apply(ids, movingRowAt: 1, to: 0) == ["b", "a", "c"])
    }

    @Test("drop onto own slot is a no-op")
    func dropOnSelf() {
        let ids = ["a", "b", "c"]
        #expect(PinnedReorder.apply(ids, movingRowAt: 1, to: 1) == ids)
    }

    @Test("drop just below own slot is a no-op")
    func dropBelowSelf() {
        let ids = ["a", "b", "c"]
        // Dropping "b" (1) above index 2 lands it back where it started.
        #expect(PinnedReorder.apply(ids, movingRowAt: 1, to: 2) == ids)
    }

    @Test("out-of-range source index leaves the list unchanged")
    func outOfRange() {
        let ids = ["a"]
        #expect(PinnedReorder.apply(ids, movingRowAt: 5, to: 0) == ids)
    }
}
