import Foundation
import Testing
@testable import BetterCmdTab

@MainActor
@Suite("RecentlyClosedStore")
struct RecentlyClosedStoreTests {

    private func freshStore() -> RecentlyClosedStore {
        let store = RecentlyClosedStore.shared
        store.clear()
        return store
    }

    @Test("records newest first")
    func newestFirst() {
        let store = freshStore()
        store.record(bundleID: "com.a", appName: "Alpha", title: "1", documentPath: nil)
        store.record(bundleID: "com.b", appName: "Beta", title: "2", documentPath: nil)
        #expect(store.entries.map(\.bundleID) == ["com.b", "com.a"])
        store.clear()
    }

    @Test("re-recording the same item moves it to the front without duplicating")
    func dedupeMovesToFront() {
        let store = freshStore()
        store.record(bundleID: "com.a", appName: "Alpha", title: "doc", documentPath: "/tmp/a")
        store.record(bundleID: "com.b", appName: "Beta", title: "2", documentPath: nil)
        store.record(bundleID: "com.a", appName: "Alpha", title: "doc", documentPath: "/tmp/a")
        #expect(store.entries.count == 2)
        #expect(store.entries.first?.bundleID == "com.a")
        store.clear()
    }

    @Test("matches filters by app name or title and respects the limit")
    func matchesFiltersAndLimits() {
        let store = freshStore()
        store.record(bundleID: "com.notes", appName: "Notes", title: "Grocery list", documentPath: nil)
        store.record(bundleID: "com.safari", appName: "Safari", title: "Apple", documentPath: nil)
        let byName = store.matches(query: "saf", limit: 5)
        #expect(byName.count == 1)
        #expect(byName.first?.bundleID == "com.safari")
        let byTitle = store.matches(query: "grocery", limit: 5)
        #expect(byTitle.first?.bundleID == "com.notes")
        #expect(store.matches(query: "", limit: 5).isEmpty)
        store.clear()
    }

    @Test("matches folds diacritics/case and stays in sync after dedupe reorders entries")
    func matchesFoldsAndTracksMutations() {
        let store = freshStore()
        store.record(bundleID: "com.cafe", appName: "Café", title: "Menù", documentPath: nil)
        store.record(bundleID: "com.beta", appName: "Beta", title: "", documentPath: nil)
        // Pre-folded entry matches an unaccented query by name and by title.
        #expect(store.matches(query: "CAFE", limit: 5).first?.bundleID == "com.cafe")
        #expect(store.matches(query: "menu", limit: 5).first?.bundleID == "com.cafe")
        // Re-recording moves the entry to the front; the folded cache must
        // follow or matches would test against the wrong entry's strings.
        store.record(bundleID: "com.cafe", appName: "Café", title: "Menù", documentPath: nil)
        #expect(store.matches(query: "cafe", limit: 5).map(\.bundleID) == ["com.cafe"])
        #expect(store.matches(query: "beta", limit: 5).map(\.bundleID) == ["com.beta"])
        store.clear()
    }

    @Test("recent returns newest entries capped at the limit")
    func recentNewestCapped() {
        let store = freshStore()
        for i in 1...6 {
            store.record(bundleID: "com.app\(i)", appName: "App \(i)", title: "", documentPath: nil)
        }
        let top3 = store.recent(limit: 3)
        #expect(top3.count == 3)
        // Newest first: app6, app5, app4.
        #expect(top3.map(\.bundleID) == ["com.app6", "com.app5", "com.app4"])
        #expect(store.recent(limit: 0).isEmpty)
        store.clear()
    }

    @Test("termination records a tracked regular app and ignores untracked pids")
    func terminationTracking() {
        let store = freshStore()
        store.noteRegularApp(pid: 4242, bundleID: "com.example.foo", name: "Foo")

        // Untracked pid (e.g. a background helper) records nothing.
        store.handleTermination(pid: 9999)
        #expect(store.entries.isEmpty)

        // Tracked pid records the identity captured while it was alive.
        store.handleTermination(pid: 4242)
        #expect(store.entries.first?.bundleID == "com.example.foo")
        #expect(store.entries.first?.appName == "Foo")

        // The pid is consumed, so a duplicate terminate does nothing.
        store.handleTermination(pid: 4242)
        #expect(store.entries.count == 1)
        store.clear()
    }

    @Test("documentURL is derived from a stored path")
    func documentURLDerivation() {
        let withDoc = RecentEntry(bundleID: "com.a", appName: "A", title: "t", documentPath: "/tmp/x.txt", closedAt: Date())
        #expect(withDoc.documentURL?.path == "/tmp/x.txt")
        let withoutDoc = RecentEntry(bundleID: "com.a", appName: "A", title: "t", documentPath: nil, closedAt: Date())
        #expect(withoutDoc.documentURL == nil)
    }
}
