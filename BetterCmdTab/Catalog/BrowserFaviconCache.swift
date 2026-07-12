import AppKit
import CryptoKit
import Foundation
import ImageIO
import SQLite3

enum BrowserFaviconCache {
    struct Request: Hashable, Sendable {
        let bundleID: String
        let url: String
    }

    private struct LoadResult {
        let images: [String: NSImage]
        let complete: Bool
    }

    private static let edge = 128
    private static let cost = edge * edge * 4
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 128 * cost
        return cache
    }()
    private static let misses: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    static func normalizedURL(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if var components = URLComponents(string: raw) {
            components.fragment = nil
            if let value = components.string, !value.isEmpty { return value }
        }
        let value = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return value.isEmpty ? nil : value
    }

    static func key(bundleID: String?, url: String) -> String? {
        guard let bundleID, let url = normalizedURL(url) else { return nil }
        return bundleID.lowercased() + "\u{1F}" + url
    }

    static func image(forKey key: String?) -> NSImage? {
        key.flatMap { images.object(forKey: $0 as NSString) }
    }

    /// Runs on the caller's background queue. All SQLite reads and image
    /// decoding finish before the caller performs its single UI refresh.
    static func load(_ requests: [Request], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let unique = Array(Set(requests)).filter {
            guard let key = key(bundleID: $0.bundleID, url: $0.url) else { return false }
            return images.object(forKey: key as NSString) == nil && misses.object(forKey: key as NSString) == nil
        }
        guard !unique.isEmpty else { return }

        for group in Dictionary(grouping: unique, by: { $0.bundleID.lowercased() }) {
            let bundleID = group.key
            let requests = group.value
            let loaded: LoadResult
            switch BrowserTabs.Family.from(bundleID: bundleID) {
            case .safari:
                let root = safariDirectory(bundleID: bundleID, home: home)
                loaded = loadSafariResult(urls: requests.map(\.url), databaseURL: root.appendingPathComponent("favicons.db"), iconsURL: root.appendingPathComponent("favicons"))
            case .chromium:
                guard let root = chromiumDirectory(bundleID: bundleID, home: home) else { continue }
                loaded = loadChromiumResult(urls: requests.map(\.url), dataDirectory: root)
            case nil:
                continue
            }
            for request in requests {
                guard let normalized = normalizedURL(request.url),
                      let cacheKey = key(bundleID: bundleID, url: normalized) else { continue }
                if let image = loaded.images[normalized] {
                    images.setObject(image, forKey: cacheKey as NSString, cost: cost)
                } else if loaded.complete {
                    misses.setObject(1, forKey: cacheKey as NSString)
                }
            }
        }
    }

    static func loadSafari(urls: [String], databaseURL: URL, iconsURL: URL) -> [String: NSImage] {
        loadSafariResult(urls: urls, databaseURL: databaseURL, iconsURL: iconsURL).images
    }

    private static func loadSafariResult(urls: [String], databaseURL: URL, iconsURL: URL) -> LoadResult {
        let normalized = Array(Set(urls.compactMap(normalizedURL)))
        guard !normalized.isEmpty else { return LoadResult(images: [:], complete: true) }
        return withDatabase(at: databaseURL) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT uuid FROM page_url WHERE url = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return LoadResult(images: [:], complete: false) }
            defer { sqlite3_finalize(statement) }
            var result: [String: NSImage] = [:]
            var complete = true
            for url in normalized {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, url, -1, SQLITE_TRANSIENT)
                let status = sqlite3_step(statement)
                guard status == SQLITE_ROW else {
                    if status != SQLITE_DONE { complete = false }
                    continue
                }
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                let uuid = String(cString: text)
                let digest = Insecure.MD5.hash(data: Data(uuid.utf8)).map { String(format: "%02X", $0) }.joined()
                if let image = decode(iconsURL.appendingPathComponent(digest)) { result[url] = image }
            }
            return LoadResult(images: result, complete: complete)
        } ?? LoadResult(images: [:], complete: false)
    }

    static func loadChromium(urls: [String], dataDirectory: URL) -> [String: NSImage] {
        loadChromiumResult(urls: urls, dataDirectory: dataDirectory).images
    }

    private static func loadChromiumResult(urls: [String], dataDirectory: URL) -> LoadResult {
        var unresolved = Set(urls.compactMap(normalizedURL))
        var result: [String: NSImage] = [:]
        var readDatabase = false
        var complete = true
        for profile in chromiumProfileDirectories(in: dataDirectory) where !unresolved.isEmpty {
            let databaseURL = profile.appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
            let found = loadChromiumDatabase(urls: Array(unresolved), databaseURL: databaseURL)
            readDatabase = readDatabase || found.complete
            complete = complete && found.complete
            result.merge(found.images) { current, _ in current }
            unresolved.subtract(found.images.keys)
        }
        return LoadResult(images: result, complete: readDatabase && complete)
    }

    static func chromiumProfileDirectories(in root: URL) -> [URL] {
        let localState = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any] else {
            return [root, root.appendingPathComponent("Default")]
        }
        let lastUsed = profile["last_used"] as? String
        let active = profile["last_active_profiles"] as? [String] ?? []
        let known = (profile["info_cache"] as? [String: Any])?.keys.sorted() ?? []
        var names: [String] = []
        for name in [lastUsed].compactMap({ $0 }) + active + known where !names.contains(name) {
            names.append(name)
        }
        return names.map { root.appendingPathComponent($0) } + [root]
    }

    private static func loadChromiumDatabase(urls: [String], databaseURL: URL) -> LoadResult {
        return withDatabase(at: databaseURL) { db in
            let sql = """
            SELECT fb.image_data
            FROM icon_mapping im
            JOIN favicons f ON f.id = im.icon_id
            JOIN favicon_bitmaps fb ON fb.icon_id = f.id
            WHERE im.page_url = ?
            ORDER BY fb.width DESC
            LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return LoadResult(images: [:], complete: false) }
            defer { sqlite3_finalize(statement) }
            var result: [String: NSImage] = [:]
            var complete = true
            for url in urls {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, url, -1, SQLITE_TRANSIENT)
                let status = sqlite3_step(statement)
                guard status == SQLITE_ROW else {
                    if status != SQLITE_DONE { complete = false }
                    continue
                }
                guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                if let image = decode(data) { result[url] = image }
            }
            return LoadResult(images: result, complete: complete)
        } ?? LoadResult(images: [:], complete: false)
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) -> T) -> T? {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }

        func read(_ path: String, flags: Int32) -> (value: T?, status: Int32) {
            var db: OpaquePointer?
            let opened = sqlite3_open_v2(path, &db, flags, nil)
            guard opened == SQLITE_OK, let db else {
                if db != nil { sqlite3_close(db) }
                return (nil, opened)
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 20)
            let status = sqlite3_exec(db, "PRAGMA schema_version", nil, nil, nil)
            guard status == SQLITE_OK else { return (nil, status) }
            return (body(db), SQLITE_OK)
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let first = read(url.path, flags: flags)
        if let value = first.value { return value }

        // Chromium forks such as Helium keep an exclusive connection even
        // between writes. Reading the stable main file is safe only when no
        // rollback/WAL payload exists; otherwise keep the normal silent fallback.
        let primaryStatus = first.status & 0xFF
        guard primaryStatus == SQLITE_BUSY || primaryStatus == SQLITE_LOCKED,
              !hasData(atPath: url.path + "-wal"),
              !hasData(atPath: url.path + "-journal") else { return nil }
        return read(url.absoluteString + "?immutable=1", flags: flags | SQLITE_OPEN_URI).value
    }

    private static func hasData(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private static func decode(_ url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
              ] as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil).flatMap(downscaled)
        guard let image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func downscaled(_ image: CGImage) -> CGImage? {
        guard image.width > edge || image.height > edge else { return image }
        let scale = min(CGFloat(edge) / CGFloat(image.width), CGFloat(edge) / CGFloat(image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func safariDirectory(bundleID: String, home: URL) -> URL {
        let name = bundleID == "com.apple.safaritechnologypreview" ? "SafariTechnologyPreview" : "Safari"
        return home.appendingPathComponent("Library/\(name)/Favicon Cache")
    }

    static func chromiumDirectory(bundleID: String, home: URL) -> URL? {
        let relative: [String: String] = [
            "com.google.chrome": "Google/Chrome",
            "com.google.chrome.canary": "Google/Chrome Canary",
            "com.google.chrome.beta": "Google/Chrome Beta",
            "com.google.chrome.dev": "Google/Chrome Dev",
            "com.brave.browser": "BraveSoftware/Brave-Browser",
            "com.brave.browser.beta": "BraveSoftware/Brave-Browser-Beta",
            "com.brave.browser.nightly": "BraveSoftware/Brave-Browser-Nightly",
            "com.brave.browser.dev": "BraveSoftware/Brave-Browser-Dev",
            "com.microsoft.edgemac": "Microsoft Edge",
            "com.microsoft.edgemac.beta": "Microsoft Edge Beta",
            "com.microsoft.edgemac.dev": "Microsoft Edge Dev",
            "com.microsoft.edgemac.canary": "Microsoft Edge Canary",
            "com.vivaldi.vivaldi": "Vivaldi",
            "com.operasoftware.opera": "com.operasoftware.Opera",
            "com.operasoftware.operadeveloper": "com.operasoftware.OperaDeveloper",
            "company.thebrowser.browser": "Arc/User Data",
            "company.thebrowser.dia": "Dia/User Data",
            "net.imput.helium": "net.imput.helium",
        ]
        guard let path = relative[bundleID.lowercased()] else { return nil }
        return home.appendingPathComponent("Library/Application Support/\(path)")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
