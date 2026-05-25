import CoreAudio
import Foundation

/// Tracks which processes are currently producing audio output so the switcher
/// can flag "this app is playing sound" rows. Backed by CoreAudio's process
/// object API, which is macOS 14.4+; on older systems the set stays empty and
/// the indicator simply never shows.
///
/// The set is recomputed on demand (`refresh()` at reveal time) rather than via
/// a property listener — a switch session is brief, so a single snapshot per
/// reveal is both cheap and fresh enough.
@MainActor
final class AudioActivityMonitor {
    static let shared = AudioActivityMonitor()

    private var playingPids: Set<pid_t> = []

    private init() {}

    func isPlaying(_ pid: pid_t) -> Bool { playingPids.contains(pid) }

    func refresh() {
        if #available(macOS 14.4, *) {
            playingPids = Self.computePlayingPids()
        } else {
            playingPids = []
        }
    }

    @available(macOS 14.4, *)
    private static func computePlayingPids() -> Set<pid_t> {
        let system = AudioObjectID(kAudioObjectSystemObject)

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &dataSize, &objects) == noErr else {
            return []
        }

        var result: Set<pid_t> = []
        for object in objects where isRunningOutput(object) {
            if let pid = pid(of: object) { result.insert(pid) }
        }
        return result
    }

    @available(macOS 14.4, *)
    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    @available(macOS 14.4, *)
    private static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid) == noErr, pid > 0 else {
            return nil
        }
        return pid
    }
}
