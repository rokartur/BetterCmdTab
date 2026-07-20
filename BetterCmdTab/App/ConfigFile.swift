import Combine
import Foundation
import os

/// Ghostty-style file-based configuration (#117): a live two-way sync between
/// the `Switcher.*` preferences and `~/.config/bettercmdtab/config.json`
/// (flat JSON, see `SettingsPortability`).
///
/// The file's existence is the opt-in switch. File present → its edits apply
/// live (event-driven watcher, no polling) and GUI changes are written back
/// (debounced), so the file and the GUI never diverge. File absent → fully
/// dormant; it is never created uninvited. Deleting the file stops the sync.
///
/// Deliberate semantics: any applied change (file edit or GUI) converges the
/// file to the full canonical snapshot — a hand-written partial file gets
/// expanded and custom formatting normalized. That is the cost of "never
/// diverge"; preserving user formatting would mean tracking which keys the
/// file contained.
///
/// All mutable state is confined to `queue` (hence `@unchecked Sendable`).
final class ConfigFile: @unchecked Sendable {
    static let shared = ConfigFile()

    /// `$XDG_CONFIG_HOME` (only when absolute, per the XDG spec) or
    /// `~/.config`, plus `bettercmdtab/config.json`.
    static let url: URL = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("bettercmdtab/config.json", isDirectory: false)
    }()

    static var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private let queue = DispatchQueue(label: "pro.bettercmdtab.config", qos: .utility)
    // Queue-confined state.
    private var source: DispatchSourceFileSystemObject?
    private var watchingFile = false
    /// Raw bytes last read from or written to the file. The echo guard: our
    /// own atomic write fires the watcher, the re-read compares equal and the
    /// reload is skipped — no suppression flags needed (`exportedJSONData()`
    /// is byte-deterministic via `.sortedKeys`).
    private var lastSyncedData: Data?
    private var pendingReload: DispatchWorkItem?
    private var writeBack: AnyCancellable?

    private init() {}

    /// Boot the watcher and the GUI→file write-back. Idempotent; called from
    /// AppDelegate at launch and after `createFileAndActivate()`.
    @MainActor
    func start() {
        if writeBack == nil {
            writeBack = Preferences.shared.objectWillChange
                .debounce(for: .milliseconds(500), scheduler: queue)
                .sink { [weak self] _ in self?.writeBackLocked() }
        }
        queue.async { [self] in
            armWatcher()
            if watchingFile { scheduleReloadLocked() }
        }
    }

    /// Write the current settings to the config file (creating directories as
    /// needed) and start syncing. The one-shot main-thread IO is a settings
    /// button, not a hot path; synchronous so the button can surface errors.
    @MainActor
    func createFileAndActivate() throws {
        try FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Preferences.exportedJSONData()
        try data.write(to: Self.url.resolvingSymlinksInPath(), options: .atomic)
        queue.async { [self] in lastSyncedData = data }
        start()
    }

    /// Synchronously flush any pending GUI change to the file. Called at quit:
    /// the 500 ms debounce would otherwise drop a just-made change, and the
    /// stale file would revert it at next launch. No-ops when not syncing or
    /// nothing changed; never hops to the main actor, so `queue.sync` from the
    /// main thread cannot deadlock.
    func flush() {
        queue.sync { writeBackLocked() }
    }

    // MARK: - Queue-confined

    /// (Re)attach the watcher: the file itself when it exists, otherwise the
    /// nearest existing parent directory so a file created while running is
    /// picked up.
    private func armWatcher() {
        source?.cancel()
        source = nil
        watchingFile = false

        let path = Self.url.path
        let fd = open(path, O_EVTONLY) // follows symlinks — watches the real target
        if fd >= 0 {
            watchingFile = true
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
            src.setCancelHandler { close(fd) }
            src.setEventHandler { [weak self, weak src] in
                guard let self, let src else { return }
                if !src.data.intersection([.delete, .rename]).isEmpty {
                    // Atomic editor save (write temp → rename over the path)
                    // replaced the inode; re-open to follow the new file.
                    self.armWatcher()
                }
                self.scheduleReloadLocked()
            }
            source = src
            src.activate()
            return
        }

        let dir = Self.url.deletingLastPathComponent()
        for candidate in [dir, dir.deletingLastPathComponent()] {
            let dirFD = open(candidate.path, O_EVTONLY)
            guard dirFD >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD, eventMask: .write, queue: queue)
            src.setCancelHandler { close(dirFD) }
            src.setEventHandler { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: path) else { return }
                self.armWatcher()
                if self.watchingFile { self.scheduleReloadLocked() }
            }
            source = src
            src.activate()
            return
        }
        // ponytail: no watcher when neither $XDG_CONFIG_HOME/~/.config nor
        // bettercmdtab/ exists — watching $HOME for ".config" to appear would
        // fire on every dotfile write (polling through another door). Creating
        // the chain externally mid-session needs a relaunch or the Create button.
        Log.config.debug("config file and its directories absent; file-based config dormant")
    }

    /// Coalesce editor write bursts, then read + apply off the main thread.
    private func scheduleReloadLocked() {
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadLocked() }
        pendingReload = item
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: item)
    }

    private func reloadLocked() {
        guard let data = try? Data(contentsOf: Self.url), data != lastSyncedData else { return }
        // Remember even a malformed read so the same bad bytes aren't re-parsed
        // on every event; a fixed file differs and reloads.
        lastSyncedData = data
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                do {
                    try Preferences.shared.importSettings(from: data)
                    Log.config.info("config file applied")
                } catch {
                    // Never wipe settings over a bad file — keep current values.
                    Log.config.warning("config file rejected: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Debounced GUI→file sync. Dormant unless the file itself is being
    /// watched — never creates the file uninvited.
    private func writeBackLocked() {
        guard watchingFile,
              let data = try? Preferences.exportedJSONData(),
              data != lastSyncedData else { return }
        lastSyncedData = data
        do {
            // Resolve symlinks so the atomic write (temp + rename) replaces the
            // link's target, not the link itself (dotfiles setups).
            try data.write(to: Self.url.resolvingSymlinksInPath(), options: .atomic)
        } catch {
            Log.config.warning("config write-back failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
