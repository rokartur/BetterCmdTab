import AppKit
import os
import UniformTypeIdentifiers

/// Optional sensory feedback played the moment the switcher commits a
/// selection. Both channels are off by default and read live from Preferences,
/// so toggling them takes effect on the next commit without a restart.
@MainActor
enum CommitFeedback {
    private static let fallbackSoundName = Preferences.defaultCommitSoundName
    private static var cachedSoundName = ""
    private static var cachedCustomFilename: String?
    private static var cachedSound: NSSound?
    private static var hasLoadedSound = false

    private enum CustomSoundError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            String(localized: "The selected file isn't a supported sound.")
        }
    }

    /// Read only when the General pane is built, never while opening or
    /// committing the switcher.
    static func systemSoundNames() -> [String] {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        var names = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.compactMap { url -> String? in
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else { return nil }
            return url.deletingPathExtension().lastPathComponent
        } ?? []
        if !names.contains(fallbackSoundName) { names.append(fallbackSoundName) }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func selectSystemSound(named name: String) {
        let prefs = Preferences.shared
        let oldCustomFilename = prefs.customCommitSoundFilename
        prefs.commitSoundName = name
        prefs.customCommitSoundFilename = nil
        invalidateSoundCache()
        if let oldCustomFilename, let url = customSoundURL(for: oldCustomFilename) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func installCustomSound(from sourceURL: URL) throws {
        let destination = try copyCustomSound(from: sourceURL, to: customSoundsDirectory)

        let prefs = Preferences.shared
        let oldCustomFilename = prefs.customCommitSoundFilename
        prefs.customCommitSoundFilename = destination.lastPathComponent
        invalidateSoundCache()
        if let oldCustomFilename,
           oldCustomFilename != destination.lastPathComponent,
           let oldURL = customSoundURL(for: oldCustomFilename) {
            try? FileManager.default.removeItem(at: oldURL)
        }
    }

    static func copyCustomSound(from sourceURL: URL, to directory: URL) throws -> URL {
        guard NSSound(contentsOf: sourceURL, byReference: true) != nil else {
            throw CustomSoundError.unsupported
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent
        guard !filename.isEmpty else { throw CustomSoundError.unsupported }
        let destination = directory.appendingPathComponent(filename)
        let ext = sourceURL.pathExtension
        let temporaryBase = directory.appendingPathComponent(".CustomSwitchSound-\(UUID().uuidString)")
        let temporary = ext.isEmpty ? temporaryBase : temporaryBase.appendingPathExtension(ext)

        do {
            try fileManager.copyItem(at: sourceURL, to: temporary)
            guard NSSound(contentsOf: temporary, byReference: true) != nil else {
                throw CustomSoundError.unsupported
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    static func prepare() {
        let prefs = Preferences.shared
        if prefs.soundOnCommit { _ = selectedSound(using: prefs) }
    }

    static func play() {
        let prefs = Preferences.shared

        if prefs.hapticOnCommit {
            // `.alignment` is the lightest of the three patterns — a single soft
            // tap. No-op on hardware without a Force Touch trackpad.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }

        guard prefs.soundOnCommit, let sound = selectedSound(using: prefs) else { return }
        restart(sound)
    }

    static func preview() {
        guard let sound = selectedSound(using: Preferences.shared) else { return }
        restart(sound)
    }

    static func stop() {
        if cachedSound?.isPlaying == true { cachedSound?.stop() }
    }

    private static var customSoundsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterCmdTab", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private static func customSoundURL(for filename: String) -> URL? {
        guard URL(fileURLWithPath: filename).lastPathComponent == filename else { return nil }
        return customSoundsDirectory.appendingPathComponent(filename)
    }

    private static func selectedSound(using prefs: Preferences) -> NSSound? {
        if hasLoadedSound,
           cachedSoundName == prefs.commitSoundName,
           cachedCustomFilename == prefs.customCommitSoundFilename {
            return cachedSound
        }

        hasLoadedSound = true
        cachedSoundName = prefs.commitSoundName
        cachedCustomFilename = prefs.customCommitSoundFilename

        if let filename = prefs.customCommitSoundFilename {
            if let url = customSoundURL(for: filename),
               let sound = NSSound(contentsOf: url, byReference: true) {
                cachedSound = sound
                return sound
            }
            Log.ui.warning("Could not load custom switch sound; using the system fallback")
        }

        cachedSound = NSSound(named: NSSound.Name(prefs.commitSoundName))
            ?? NSSound(named: NSSound.Name(fallbackSoundName))
        return cachedSound
    }

    private static func invalidateSoundCache() {
        cachedSound?.stop()
        cachedSound = nil
        hasLoadedSound = false
    }

    private static func restart(_ sound: NSSound) {
        // Restart from the top if a previous sound is still ringing out so
        // rapid commits each get feedback instead of being swallowed.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
