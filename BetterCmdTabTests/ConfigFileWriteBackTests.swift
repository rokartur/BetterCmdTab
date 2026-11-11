import Foundation
import Testing
@testable import BetterCmdTab

@Suite("Config file write-back")
struct ConfigFileWriteBackTests {
    private let snapshot = Data("{\"a\":1}".utf8)
    private let onDisk = Data("{\"a\":1,}".utf8)

    @Test func rejectedReadBlocksWriteBack() {
        #expect(!ConfigFile.shouldWriteBack(watchingFile: true, lastReadRejected: true, data: snapshot, lastSynced: onDisk))
    }

    @Test func acceptedReadWritesChangedSnapshot() {
        #expect(ConfigFile.shouldWriteBack(watchingFile: true, lastReadRejected: false, data: snapshot, lastSynced: onDisk))
    }

    @Test func unchangedSnapshotIsNotRewritten() {
        #expect(!ConfigFile.shouldWriteBack(watchingFile: true, lastReadRejected: false, data: snapshot, lastSynced: snapshot))
    }

    @Test func dormantWithoutTheFile() {
        #expect(!ConfigFile.shouldWriteBack(watchingFile: false, lastReadRejected: false, data: snapshot, lastSynced: nil))
    }
}
