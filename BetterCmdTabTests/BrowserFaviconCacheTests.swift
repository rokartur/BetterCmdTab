import AppKit
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import BetterCmdTab

@Suite("BrowserFaviconCache")
struct BrowserFaviconCacheTests {
    @Test("Safari reads PNG and ICO files and ignores URL fragments")
    func safariPNGAndICO() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let icons = root.appendingPathComponent("favicons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("favicons.db")
        let db = try open(database)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE page_url (url TEXT UNIQUE, uuid TEXT NOT NULL)")

        let pngUUID = "11111111-1111-1111-1111-111111111111"
        let icoUUID = "22222222-2222-2222-2222-222222222222"
        try exec(db, "INSERT INTO page_url VALUES ('https://example.test/page', '\(pngUUID)')")
        try exec(db, "INSERT INTO page_url VALUES ('https://example.test/icon', '\(icoUUID)')")
        try png(size: 2).write(to: icons.appendingPathComponent(md5(pngUUID)))
        try ico(size: 16).write(to: icons.appendingPathComponent(md5(icoUUID)))

        let found = BrowserFaviconCache.loadSafari(
            urls: ["https://example.test/page#section", "https://example.test/icon"],
            databaseURL: database,
            iconsURL: icons
        )
        #expect(found["https://example.test/page"]?.size.width == 2)
        #expect(found["https://example.test/icon"] != nil)
    }

    @Test("Chromium starts with last_used, decodes data, and falls back silently")
    func chromiumProfilesAndFailures() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localState: [String: Any] = ["profile": [
            "last_used": "Profile 2",
            "info_cache": ["Default": [:], "Profile 2": [:]],
        ]]
        try JSONSerialization.data(withJSONObject: localState).write(to: root.appendingPathComponent("Local State"))
        let profile2 = root.appendingPathComponent("Profile 2")
        let defaultProfile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
        try makeChromiumDB(profile2.appendingPathComponent("Favicons"), url: "https://example.test/page", data: png(size: 4))
        try makeChromiumDB(defaultProfile.appendingPathComponent("Favicons"), url: "https://example.test/page", data: png(size: 2))

        let profiles = BrowserFaviconCache.chromiumProfileDirectories(in: root)
        #expect(profiles.first?.path == profile2.path)
        let found = BrowserFaviconCache.loadChromium(urls: ["https://example.test/page#fragment", "https://missing.test"], dataDirectory: root)
        #expect(found["https://example.test/page"]?.size.width == 4)
        #expect(found["https://missing.test"] == nil)

        let broken = root.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let brokenDB = try open(broken.appendingPathComponent("Favicons"))
        try exec(brokenDB, "CREATE TABLE unrelated (value TEXT)")
        sqlite3_close(brokenDB)
        #expect(BrowserFaviconCache.loadChromium(urls: ["https://example.test/page"], dataDirectory: broken).isEmpty)
    }

    @Test("missing Local State checks only root and Default")
    func chromiumFallbackProfiles() {
        let root = URL(fileURLWithPath: "/tmp/no-local-state")
        #expect(BrowserFaviconCache.chromiumProfileDirectories(in: root) == [
            root,
            root.appendingPathComponent("Default"),
        ])
    }

    @Test("Chromium exclusive idle lock still permits a stable read")
    func chromiumExclusiveLock() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let database = profile.appendingPathComponent("Favicons")
        try makeChromiumDB(database, url: "https://example.test/page", data: png(size: 3))

        let lock = try open(database)
        defer { sqlite3_close(lock) }
        try exec(lock, "PRAGMA locking_mode=EXCLUSIVE")
        try exec(lock, "BEGIN EXCLUSIVE")

        let found = BrowserFaviconCache.loadChromium(
            urls: ["https://example.test/page"],
            dataDirectory: root
        )
        #expect(found["https://example.test/page"]?.size.width == 3)
    }

    @Test("a transient database failure is retried instead of cached as a miss")
    func transientDatabaseFailureIsRetried() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = "https://\(UUID().uuidString).test/page"
        let request = BrowserFaviconCache.Request(bundleID: "com.apple.Safari", url: url)
        let key = BrowserFaviconCache.key(bundleID: request.bundleID, url: url)

        BrowserFaviconCache.load([request], home: home)
        #expect(BrowserFaviconCache.image(forKey: key) == nil)

        let root = home.appendingPathComponent("Library/Safari/Favicon Cache")
        let icons = root.appendingPathComponent("favicons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("favicons.db")
        let db = try open(database)
        try exec(db, "CREATE TABLE page_url (url TEXT UNIQUE, uuid TEXT NOT NULL)")
        let uuid = UUID().uuidString
        try exec(db, "INSERT INTO page_url VALUES ('\(url)', '\(uuid)')")
        sqlite3_close(db)
        try png(size: 3).write(to: icons.appendingPathComponent(md5(uuid)))

        BrowserFaviconCache.load([request], home: home)
        #expect(BrowserFaviconCache.image(forKey: key)?.size.width == 3)
    }

    @Test("every supported Chromium bundle has a data directory")
    func chromiumBundleDirectories() {
        let ids = [
            "com.google.chrome", "com.google.chrome.canary", "com.google.chrome.beta", "com.google.chrome.dev",
            "com.brave.browser", "com.brave.browser.beta", "com.brave.browser.nightly", "com.brave.browser.dev",
            "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.microsoft.edgemac.canary",
            "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.operasoftware.operadeveloper",
            "company.thebrowser.browser", "company.thebrowser.dia", "net.imput.helium",
        ]
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(ids.allSatisfy { BrowserFaviconCache.chromiumDirectory(bundleID: $0, home: home) != nil })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw TestError.sqlite }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
    }

    private func makeChromiumDB(_ url: URL, url pageURL: String, data: Data) throws {
        let db = try open(url)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, page_url TEXT, icon_id INTEGER)")
        try exec(db, "CREATE TABLE favicons (id INTEGER PRIMARY KEY, url TEXT)")
        try exec(db, "CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER, image_data BLOB, width INTEGER)")
        try exec(db, "INSERT INTO icon_mapping VALUES (1, '\(pageURL)', 1)")
        try exec(db, "INSERT INTO favicons VALUES (1, 'icon')")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO favicon_bitmaps VALUES (1, 1, ?, 128)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw TestError.sqlite }
        defer { sqlite3_finalize(statement) }
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), testSQLiteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TestError.sqlite }
    }

    private func png(size: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = rep.representation(using: .png, properties: [:]) else { throw TestError.image }
        return data
    }

    private func ico(size: Int) throws -> Data {
        guard let source = NSBitmapImageRep(data: try png(size: size)),
              let image = source.cgImage else { throw TestError.image }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "com.microsoft.ico" as CFString,
            1,
            nil
        ) else { throw TestError.image }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.image }
        return data as Data
    }

    private func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private enum TestError: Error { case sqlite, image }
}

private let testSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
