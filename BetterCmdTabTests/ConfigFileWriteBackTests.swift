import Foundation
import Testing
@testable import BetterCmdTab

@Suite("Config file write-back")
struct ConfigFileWriteBackTests {
    private let snapshot = Data("{\"a\":1}".utf8)
    private let fileA = Data("{\"a\":2}".utf8)
    private let fileB = Data("{\"a\":2,}".utf8)

    @Test func readBlocksWriteBackUntilItsImportSucceeds() {
        var sync = ConfigFile.SyncState()
        sync.read(fileB)
        #expect(!sync.shouldWrite(snapshot))
        sync.imported(fileB)
        #expect(sync.shouldWrite(snapshot))
    }

    @Test func olderImportDoesNotClearANewerRead() {
        var sync = ConfigFile.SyncState()
        sync.read(fileA)
        sync.read(fileB)
        sync.imported(fileA)
        #expect(!sync.shouldWrite(snapshot))
    }

    @Test func creatingTheFileUnblocksWriteBack() {
        var sync = ConfigFile.SyncState()
        sync.read(fileB)
        sync.wrote(fileA)
        #expect(sync.shouldWrite(snapshot))
    }

    @Test func unchangedSnapshotIsNotRewritten() {
        var sync = ConfigFile.SyncState()
        sync.wrote(snapshot)
        #expect(!sync.shouldWrite(snapshot))
    }
}
