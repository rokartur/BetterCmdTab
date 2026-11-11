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
/// Watcher/sync state (`source`, `watchingFile`, `lastSyncedData`,
/// `lastReadRejected`, `pendingReload`) is confined to `queue`; the `writeBack` subscription is
/// touched only from `@MainActor start()`. That confinement is what justifies
/// `@unchecked Sendable`.
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

    /// Sidecar JSON Schema, written beside the config file and pointed at by
    /// its `$schema` key so editors validate and autocomplete a hand-edited
    /// file. Regenerated from the running build (see
    /// `Preferences.settingsSchema`), so it never lags a version.
    static let schemaURL = url.deletingLastPathComponent()
        .appendingPathComponent("schema.json", isDirectory: false)

    /// Relative on purpose (resolves against the config file's own directory)
    /// and slash-free so `JSONSerialization` doesn't escape it into `".\/…"`.
    private static let schemaRef = "schema.json"

    static var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The config snapshot plus its `$schema` pointer. `$schema` is excluded
    /// from import, so the round trip stays a no-op setting-wise.
    private static func configData() throws -> Data {
        var values = Preferences.flatSettingsSnapshot()
        values["$schema"] = schemaRef
        return try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    }

    private let queue = DispatchQueue(label: "pro.bettercmdtab.config", qos: .utility)
    // Queue-confined state.
    private var source: DispatchSourceFileSystemObject?
    private var watchingFile = false
    /// Raw bytes last read from or written to the file. The echo guard: our
    /// own atomic write fires the watcher, the re-read compares equal and the
    /// reload is skipped — no suppression flags needed (`configData()` is
    /// byte-deterministic via `.sortedKeys`).
    private var lastSyncedData: Data?
    private var lastReadRejected = false
    /// Bytes last written to `schemaURL`, seeded from disk on first use so an
    /// unchanged schema costs no write at launch.
    private var lastSchemaData: Data?
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
            if watchingFile {
                // Covers an upgrade that added keys: the schema refreshes at
                // launch even if no setting is touched this session.
                syncSchemaLocked()
                scheduleReloadLocked()
            } else {
                // No file for this launch to date, so the re-base token has
                // nothing left to explain: a config written into the watched
                // directory later in the session means the sizes it spells.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Preferences.preRebasePanelScales = nil }
                }
            }
        }
    }

    /// Write the current settings to the config file (creating directories as
    /// needed) and start syncing. The one-shot main-thread IO is a settings
    /// button, not a hot path; synchronous so the button can surface errors.
    @MainActor
    func createFileAndActivate() throws {
        try FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.configData()
        try data.write(to: Self.url.resolvingSymlinksInPath(), options: .atomic)
        // These bytes are this build's own snapshot, so they post-date the
        // re-base by construction and end the token's usefulness with them.
        Preferences.preRebasePanelScales = nil
        queue.async { [self] in
            lastSyncedData = data
            lastReadRejected = false
        }
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

    /// (Re)attach the watcher: the file itself when it exists, otherwise our own
    /// `bettercmdtab/` directory so a file created while running is picked up.
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
                if !src.data.isDisjoint(with: [.delete, .rename]) {
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

        // Only ever watch bettercmdtab/, never its parent: ~/.config is written
        // constantly by unrelated tools, and each such write would wake this
        // queue for a stat on behalf of a feature the user never enabled.
        let dir = Self.url.deletingLastPathComponent()
        let dirFD = open(dir.path, O_EVTONLY)
        if dirFD >= 0 {
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
        // ponytail: no watcher when bettercmdtab/ itself is absent — watching a
        // parent for it to appear would fire on every unrelated dotfile write
        // (polling through another door). Creating the directory externally
        // mid-session needs a relaunch or the Create button.
        Log.config.debug("config directory absent; file-based config dormant")
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
        // Held until the import succeeds, so a write-back never lands on an unparsed file.
        lastReadRejected = true
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                do {
                    try Preferences.shared.importSettings(from: data, mayPredateNativeSizing: true)
                    // A newer read may be waiting on its own verdict; only these bytes are cleared.
                    queue.async { [self] in if lastSyncedData == data { lastReadRejected = false } }
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
        // watchingFile first: a dormant sync must not pay for a snapshot per settings change.
        guard watchingFile,
              let data = try? Self.configData(),
              Self.shouldWriteBack(watchingFile: watchingFile, lastReadRejected: lastReadRejected, data: data, lastSynced: lastSyncedData) else { return }
        // A key can appear mid-session (a preference written for the first
        // time); keep the schema in step with what we're about to write.
        syncSchemaLocked()
        do {
            // Resolve symlinks so the atomic write (temp + rename) replaces the
            // link's target, not the link itself (dotfiles setups).
            try data.write(to: Self.url.resolvingSymlinksInPath(), options: .atomic)
            // Arm the echo guard only once the bytes are on disk. Arming it
            // first would make a failed write look converged, and the next
            // reload would re-import the stale file over the user's change.
            lastSyncedData = data
        } catch {
            Log.config.warning("config write-back failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func shouldWriteBack(watchingFile: Bool, lastReadRejected: Bool, data: Data, lastSynced: Data?) -> Bool {
        watchingFile && !lastReadRejected && data != lastSynced
    }

    /// Write the sidecar schema when its bytes changed. Only ever runs while
    /// the config file itself is synced, so nothing is created uninvited.
    private func syncSchemaLocked() {
        guard watchingFile, let data = try? Preferences.settingsSchemaData() else { return }
        if lastSchemaData == nil { lastSchemaData = try? Data(contentsOf: Self.schemaURL) }
        guard data != lastSchemaData else { return }
        do {
            try data.write(to: Self.schemaURL.resolvingSymlinksInPath(), options: .atomic)
            lastSchemaData = data
        } catch {
            Log.config.warning("config schema write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
