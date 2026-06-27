import AppKit
import ApplicationServices
import Darwin
import Foundation
import os

// Private SPI from libsystem: detaches the spawned child's TCC
// "responsibility" so it acts as its own client (osascript) instead of
// inheriting from us (BetterCmdTab). This is the documented escape hatch
// when an LSUIElement agent can't surface Apple Events TCC prompts — a known
// gap on macOS Tahoe (26). Same symbol that Witch, TabTab, and several other
// shipping switchers use.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// Per-browser tab enumeration + activation via Apple Events. AX scraping is
/// unreliable across Safari/Chromium versions (the tab strip is deeply nested
/// and frequently restructured); the scripting dictionaries every major browser
/// ships are the only stable interface for "list tabs of window N" and "select
/// tab N of window N".
///
/// All three operations (raise window, list tabs, select tab) are bound to the
/// `AppleScript window 1` of the target app. Since we cannot map an AX window
/// to a stable AppleScript window index, we first force the row's window to be
/// the browser's frontmost via `AXRaiseAction` and a brief delay so subsequent
/// scripts read the right window.
enum BrowserTabs {

    /// Result of a tab-enumeration attempt. `failed` distinguishes a script
    /// error (Automation permission denied, timeout) from a browser that simply
    /// has too few tabs to drill — the caller surfaces a hint only for `failed`.
    enum TabsOutcome {
        case notSupported
        case failed
        case tabs([String])
    }

    enum Family {
        case chromium  // Chrome, Brave, Edge, Vivaldi, Opera, Arc, Dia
        case safari    // Safari, Safari Technology Preview

        static func from(bundleID: String?) -> Family? {
            guard let id = bundleID?.lowercased() else { return nil }
            // Chromium family: bundle IDs use a stable AppleScript dictionary
            // identical to Chrome's. Arc and Dia (The Browser Company) also
            // adopt the same dialect.
            let chromiumIDs: Set<String> = [
                "com.google.chrome",
                "com.google.chrome.canary",
                "com.google.chrome.beta",
                "com.google.chrome.dev",
                "com.brave.browser",
                "com.brave.browser.beta",
                "com.brave.browser.nightly",
                "com.brave.browser.dev",
                "com.microsoft.edgemac",
                "com.microsoft.edgemac.beta",
                "com.microsoft.edgemac.dev",
                "com.microsoft.edgemac.canary",
                "com.vivaldi.vivaldi",
                "com.operasoftware.opera",
                "com.operasoftware.operadeveloper",
                "company.thebrowser.browser",
                "company.thebrowser.dia",
                "net.imput.helium",
            ]
            if chromiumIDs.contains(id) { return .chromium }
            if id == "com.apple.safari" || id == "com.apple.safaritechnologypreview" { return .safari }
            return nil
        }
    }

    /// Quote a string for embedding inside an AppleScript string literal.
    /// AppleScript needs `\` and `"` escaped; everything else can stay as-is.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript identifier prefix for an app — `application id "com.foo"`.
    /// Using the bundle ID instead of the name avoids localization issues and
    /// is rejected gracefully if the app isn't installed (returns an empty
    /// title list rather than failing the script).
    private static func appLiteral(_ bundleID: String) -> String {
        "application id \"\(escape(bundleID))\""
    }

    /// Force the row's window to be the browser's frontmost window so the
    /// subsequent `window 1` scripts target it. Synchronous AX call, runs on
    /// the caller's queue. Does NOT activate the process — keeps the panel
    /// visible. Skips entirely when the app has only one window: there's no
    /// "wrong window" to raise away from, and the AX call still costs ~10ms
    /// even for a no-op raise.
    private static func raiseInBrowser(_ window: AXUIElement, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
        let windowCount = (windowsValue as? [AXUIElement])?.count ?? 0
        if windowCount <= 1 { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Last-ditch commit fallback when the tab-activation script fails: bring
    /// the row's window forward without Apple Events. Unlike `raiseInBrowser`
    /// this raises unconditionally (the ≤1-window skip would drop the only
    /// window when the AX read fails) and activates the process — an AX raise
    /// alone only reorders windows inside the still-inactive browser.
    private static func bringForward(_ window: AXUIElement, app: NSRunningApplication) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if #available(macOS 14.0, *) {
            _ = app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Run an AppleScript. In-process `NSAppleScript` fails silently with
    /// -1743 on LSUIElement agents under macOS Tahoe (no TCC prompt ever
    /// appears, no entry shows up in System Settings → Privacy → Automation).
    /// We sidestep this by spawning `/usr/bin/osascript` with the
    /// `responsibility_spawnattrs_setdisclaim` SPI, which makes the child
    /// process its own TCC responsibility — so the prompt either uses
    /// osascript's pre-existing permission or surfaces correctly under
    /// osascript's name. Stdout is the script's text result, one line per
    /// item separated by ", " (osascript's default list serialization).
    private static func runScript(_ source: String) -> String? {
        var attrs: posix_spawnattr_t?
        guard posix_spawnattr_init(&attrs) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attrs) }
        _ = responsibility_spawnattrs_setdisclaim(&attrs, 1)

        let outPipe = Pipe()
        let errPipe = Pipe()
        let outFd = outPipe.fileHandleForWriting.fileDescriptor
        let errFd = errPipe.fileHandleForWriting.fileDescriptor
        // Guarantee parent-side write descriptors are released even on the
        // failure paths below. `Pipe` deinit ultimately closes them, but
        // hanging on to them until ARC drains can stack up FDs across a burst
        // of failures (e.g. repeated TCC denials). Tracked by a flag so the
        // success path can close them at exactly the right moment (after
        // spawn, before reading the child's output).
        var parentWriteClosed = false
        func closeParentWriteEnds() {
            guard !parentWriteClosed else { return }
            parentWriteClosed = true
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
        }
        defer { closeParentWriteEnds() }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outFd, 1)
        posix_spawn_file_actions_adddup2(&actions, errFd, 2)
        posix_spawn_file_actions_addclose(&actions, outFd)
        posix_spawn_file_actions_addclose(&actions, errFd)
        // Also close the parent-side *read* ends in the child so the spawned
        // osascript doesn't inherit two stray descriptors (Foundation's `Pipe`
        // does not set FD_CLOEXEC). Harmless to the EOF protocol, which depends
        // only on the write ends.
        posix_spawn_file_actions_addclose(&actions, outPipe.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, errPipe.fileHandleForReading.fileDescriptor)

        let path = "/usr/bin/osascript"
        let args: [String] = ["osascript", "-e", source]
        let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for a in cArgs where a != nil { free(a) } }

        var pid: pid_t = 0
        let status = path.withCString { cPath in
            posix_spawn(&pid, cPath, &actions, &attrs, cArgs, environ)
        }
        guard status == 0 else {
            Log.activator.error("BrowserTabs: posix_spawn osascript failed \(status)")
            return nil
        }
        closeParentWriteEnds()

        // Hard wall-clock watchdog, independent of the AppleScript `with timeout`
        // (which only bounds Apple Event *dispatch*, not the osascript process).
        // A wedged browser — or a child that stalls before the event dispatches —
        // would otherwise block this worker thread on `readDataToEndOfFile` /
        // `waitpid` indefinitely and leak a zombie. After the deadline we SIGKILL
        // the child so the pipe reads hit EOF and `waitpid` reaps it. Cancelled on
        // the normal path.
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8.0, execute: watchdog)
        defer { watchdog.cancel() }

        // Drain stdout and stderr to EOF *before* reaping. `readDataToEndOfFile`
        // returns only once the child closes its write ends (i.e. exits), and a
        // child that emits more than the ~64KB pipe buffer blocks on its `write`
        // until we read — so waiting on `waitpid` first would deadlock against a
        // browser with a large tab list. The two pipes are drained on separate
        // threads to also avoid the classic two-pipe stall (filling stderr while
        // we block reading stdout). Both EOF, then `waitpid` just reaps.
        final class DataBox: @unchecked Sendable { var data = Data() }
        let errBox = DataBox()
        let errReadHandle = errPipe.fileHandleForReading
        let errDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errReadHandle.readDataToEndOfFile()
            errDrained.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDrained.wait()
        let errData = errBox.data

        var stat: Int32 = 0
        waitpid(pid, &stat, 0)
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        // WIFEXITED/WEXITSTATUS are C macros Swift can't import: the low 7
        // status bits are 0 only on a clean exit. A signaled child — typically
        // the watchdog's SIGKILL on a wedged browser — has 0 in the exit-code
        // byte and must not be mistaken for success.
        let termSignal = stat & 0x7f
        guard termSignal == 0 else {
            Log.activator.error("BrowserTabs: osascript killed by signal \(termSignal) stderr=\(stderr)")
            return nil
        }
        let exitCode = (stat & 0xff00) >> 8
        if exitCode != 0 || !stderr.isEmpty {
            Log.activator.error("BrowserTabs: osascript exit=\(exitCode) stderr=\(stderr)")
        }
        if exitCode != 0 { return nil }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split osascript's list output into items. AppleScript's default text
    /// representation of a list separates items with ", " — split there.
    /// Returns the raw items in declaration order.
    private static func parseList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: ", ")
    }

    /// Force the macOS TCC prompt for Apple Events to the target app. Returns
    /// true when permission is granted (now or previously). Without this the
    /// first script call fails with -1743 silently if TCC happens to suppress
    /// the prompt (already-denied / stale signature). Run off-main.
    /// Walk the running app list, pick every supported browser, and send a
    /// minimal Apple Event (`get name`) to each. On a fresh install this
    /// triggers the TCC consent prompt per browser. **Must be called while
    /// the app is foreground** — agents (`LSUIElement = YES`) without a
    /// presentable UI window don't get a prompt; TCC silently denies and the
    /// entry never appears in System Settings → Privacy → Automation. The
    /// caller is expected to be the Settings window's "Browser tab drill-in"
    /// toggle, which provides exactly that foreground context.
    /// Guards `requestPermissionForRunningBrowsers` so rapid toggles / re-opens of
    /// the Settings switch don't pile up overlapping blocking workers (each one
    /// serially round-trips every running browser).
    @MainActor private static var permissionRequestInFlight = false

    @MainActor
    static func requestPermissionForRunningBrowsers() {
        guard !permissionRequestInFlight else { return }
        // Force ourselves to the foreground so TCC has a window context.
        NSApp.activate(ignoringOtherApps: true)
        var prompted: Set<String> = []
        var bundleIDs: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier?.lowercased(),
                  Family.from(bundleID: bid) != nil,
                  prompted.insert(bid).inserted else { continue }
            bundleIDs.append(bid)
        }
        guard !bundleIDs.isEmpty else { return }
        permissionRequestInFlight = true
        // Each runScript is a blocking waitpid; doing this on the main thread
        // froze the UI for the full per-browser round-trip (multi-second on
        // installs with several browsers running).
        DispatchQueue.global(qos: .userInitiated).async {
            for bid in bundleIDs {
                let escaped = bid.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
                let source = """
                tell application id "\(escaped)"
                    with timeout of 3 seconds
                        return name
                    end timeout
                end tell
                """
                Log.activator.debug("BrowserTabs: requesting permission for \(bid)")
                _ = runScript(source)
            }
            Task { @MainActor in permissionRequestInFlight = false }
        }
    }

    @discardableResult
    static func ensurePermission(bundleID: String) -> Bool {
        guard let cString = bundleID.cString(using: .utf8) else { return false }
        var targetDesc = AEAddressDesc()
        let bidLen = bundleID.utf8.count
        let status = cString.withUnsafeBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return OSStatus(-108) /* memFullErr */ }
            return OSStatus(AECreateDesc(
                DescType(typeApplicationBundleID),
                base,
                bidLen,
                &targetDesc
            ))
        }
        guard status == noErr else { return false }
        defer { AEDisposeDesc(&targetDesc) }
        let permission = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            DescType(typeWildCard),
            DescType(typeWildCard),
            true  // askUserIfNeeded — surfaces the TCC prompt
        )
        if permission != noErr {
            Log.activator.error("BrowserTabs: AEDeterminePermissionToAutomateTarget \(bundleID) → \(permission)")
        }
        return permission == noErr
    }

    /// Enumerate the row window's tabs. Returns nil if the app isn't a
    /// supported browser; returns [] if the browser has fewer than 2 tabs
    /// (drill-in is only meaningful past 1). Run off-main.
    ///
    /// `title` is the row window's AX title. When it uniquely identifies one of
    /// the browser's windows we read that window directly (`window <index>`) and
    /// never `AXRaise` — so listing tabs no longer reorders the user's windows.
    /// Only when the title is empty/ambiguous do we fall back to the legacy
    /// raise + `window 1` path.
    static func tabTitles(for app: NSRunningApplication, window: AXUIElement, title: String) -> TabsOutcome {
        // Sending an Apple Event to a quit app relaunches it — bail if the
        // browser terminated in the race before its rows are pruned.
        if app.isTerminated { return .tabs([]) }
        guard let family = Family.from(bundleID: app.bundleIdentifier),
              let bid = app.bundleIdentifier else { return .notSupported }
        let appLit = appLiteral(bid)
        // The tab attribute (`title`/`name`) is also the window's title-ish
        // property in both dictionaries, so the same keyword matches windows.
        let attr: String = (family == .safari) ? "name" : "title"

        // Preferred path: locate the window by name, no raise.
        if !title.isEmpty {
            let lit = escape(title)
            let matchSource = """
            tell \(appLit)
                with timeout of 3 seconds
                    set wc to count of windows
                    if wc = 0 then return "NOWINDOWS"
                    set matchIdx to 0
                    set matchCount to 0
                    repeat with i from 1 to wc
                        ignoring white space
                            if (\(attr) of window i) is "\(lit)" then
                                set matchIdx to i
                                set matchCount to matchCount + 1
                            end if
                        end ignoring
                    end repeat
                    if matchCount is 1 then
                        set AppleScript's text item delimiters to (ASCII character 10)
                        return "MATCH" & (ASCII character 10) & ((\(attr) of every tab of window matchIdx) as text)
                    else
                        return "FALLBACK"
                    end if
                end timeout
            end tell
            """
            if let raw = runScript(matchSource) {
                if raw == "NOWINDOWS" { return .tabs([]) }
                if raw != "FALLBACK" {
                    let body = raw.hasPrefix("MATCH\n") ? String(raw.dropFirst("MATCH\n".count)) : raw
                    let titles = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    return .tabs(titles)
                }
                // "FALLBACK" → title didn't uniquely match; use the raise path.
            } else {
                // Script errored (permission/timeout) — don't double-spawn the
                // raise path, just report the failure.
                Log.activator.error("BrowserTabs: tabTitles \(bid) match script failed (permission/timeout?)")
                return .failed
            }
        }

        // Fallback: force the row's window frontmost and read `window 1`. `as
        // text` joins with the current delimiter (default ""), so pin it to LF
        // for unambiguous parsing even when a title contains commas.
        raiseInBrowser(window, pid: app.processIdentifier)
        let source = """
        tell \(appLit)
            with timeout of 3 seconds
                if (count of windows) = 0 then return ""
                set theList to \(attr) of every tab of window 1
            end timeout
        end tell
        set AppleScript's text item delimiters to (ASCII character 10)
        return theList as text
        """
        guard let raw = runScript(source) else {
            Log.activator.error("BrowserTabs: tabTitles \(bid) failed (permission/timeout?)")
            return .failed
        }
        let titles = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return .tabs(titles)
    }

    /// List every window of `app` together with its tab titles in a **single**
    /// Apple Events round-trip (one `osascript` spawn per browser, not one per
    /// window). The process spawn dominates the cost, so batching is both faster
    /// and lighter on CPU than calling `tabTitles` per window. No `AXRaise`, so
    /// it never reorders the user's windows.
    ///
    /// Per-window tab listing plus a `failed` flag distinguishing a script error
    /// (Automation permission denied / timeout) from a browser that genuinely has
    /// no windows or tabs. The expand-as-windows scan needs that split to surface
    /// the "grant Automation access" hint (#39) — an empty result alone can't tell
    /// "denied" from "nothing to show".
    struct AllWindowTabs {
        let windows: [(title: String, activeTab: String, tabs: [String])]
        /// True only when the osascript spawn itself failed (nil result) — a
        /// permission/timeout signal, not an empty browser.
        let failed: Bool
        static let empty = AllWindowTabs(windows: [], failed: false)
        static let failure = AllWindowTabs(windows: [], failed: true)
    }

    /// List every window of `app` together with its tab titles in a **single**
    /// Apple Events round-trip (one `osascript` spawn per browser, not one per
    /// window). The process spawn dominates the cost, so batching is both faster
    /// and lighter on CPU than calling `tabTitles` per window. No `AXRaise`, so
    /// it never reorders the user's windows.
    ///
    /// Returns `(windowTitle, activeTab, tabTitles)` per window, in window order,
    /// plus `failed` (osascript error vs. genuinely empty). The caller maps results
    /// back to its AX window elements by (trimmed) title; windows whose title isn't
    /// unique are left for the caller to skip.
    ///
    /// Records are framed with ASCII control chars that can't appear in titles:
    /// GS (29) between windows, RS (30) between a window's title, its active-tab
    /// title, and its tab list, US (31) between tabs. Run off-main.
    static func allWindowTabs(for app: NSRunningApplication) -> AllWindowTabs {
        // A quit / non-browser app is not a permission failure — nothing to grant.
        guard !app.isTerminated,
              let family = Family.from(bundleID: app.bundleIdentifier),
              let bid = app.bundleIdentifier else { return .empty }
        let appLit = appLiteral(bid)
        let attr: String = (family == .safari) ? "name" : "title"
        // A browser window's AX title reflects its active tab, so also capture the
        // active tab's title per window for the caller to match AX windows by.
        let activeExpr: String = (family == .safari)
            ? "name of current tab of window i"
            : "title of active tab of window i"
        let source = """
        tell \(appLit)
            with timeout of 5 seconds
                set wc to count of windows
                if wc is 0 then return "NOWINDOWS"
                set outText to ""
                repeat with i from 1 to wc
                    set wTitle to (\(attr) of window i) as text
                    set att to ""
                    try
                        set att to (\(activeExpr)) as text
                    end try
                    set tabNames to (\(attr) of every tab of window i)
                    set AppleScript's text item delimiters to (ASCII character 31)
                    set tabText to tabNames as text
                    set AppleScript's text item delimiters to ""
                    set outText to outText & wTitle & (ASCII character 30) & att & (ASCII character 30) & tabText
                    if i < wc then set outText to outText & (ASCII character 29)
                end repeat
                return outText
            end timeout
        end tell
        """
        guard let raw = runScript(source) else {
            Log.activator.error("BrowserTabs: allWindowTabs \(bid) failed (permission/timeout?)")
            return .failure
        }
        if raw == "NOWINDOWS" || raw.isEmpty { return .empty }
        var out: [(title: String, activeTab: String, tabs: [String])] = []
        for block in raw.components(separatedBy: "\u{1D}") {
            let parts = block.components(separatedBy: "\u{1E}")
            guard parts.count == 3 else { continue }
            let tabs = parts[2].isEmpty ? [] : parts[2].components(separatedBy: "\u{1F}")
            out.append((title: parts[0], activeTab: parts[1], tabs: tabs))
        }
        return AllWindowTabs(windows: out, failed: false)
    }

    /// Switch the row window's browser tab to `tabIndex` (0-based here, 1-based
    /// for AppleScript) and bring the browser forward. Run off-main.
    ///
    /// Like `tabTitles`, prefers to resolve the window by `title` and operate on
    /// `window <index>` (no `AXRaise`); falls back to raise + `window 1` when the
    /// title is empty/ambiguous. The `activate` (bring the app forward) stays —
    /// this is the deliberate commit, so the window coming front is expected.
    static func activateTab(at tabIndex: Int, in app: NSRunningApplication, window: AXUIElement, title: String) -> Bool {
        // Sending an Apple Event to a quit app relaunches it — bail if terminated.
        guard !app.isTerminated,
              let family = Family.from(bundleID: app.bundleIdentifier),
              let bid = app.bundleIdentifier else { return false }
        let appLit = appLiteral(bid)
        let attr: String = (family == .safari) ? "name" : "title"
        let oneBased = tabIndex + 1

        // Per-family "select tab N of <windowExpr>, raise it, activate" body.
        func selectBody(_ windowExpr: String) -> String {
            let setTab: String
            switch family {
            case .chromium:
                setTab = "set active tab index of \(windowExpr) to \(oneBased)"
            case .safari:
                setTab = "set current tab of \(windowExpr) to tab \(oneBased) of \(windowExpr)"
            }
            return """
                    set tabCount to count of tabs of \(windowExpr)
                    if \(oneBased) > tabCount then return "false"
                    \(setTab)
                    set index of \(windowExpr) to 1
                    activate
                    return "true"
            """
        }

        // Preferred path: select within the name-matched window, no raise.
        if !title.isEmpty {
            let lit = escape(title)
            let matchSource = """
            tell \(appLit)
                with timeout of 3 seconds
                    set wc to count of windows
                    if wc = 0 then return "false"
                    set matchIdx to 0
                    set matchCount to 0
                    repeat with i from 1 to wc
                        ignoring white space
                            if (\(attr) of window i) is "\(lit)" then
                                set matchIdx to i
                                set matchCount to matchCount + 1
                            end if
                        end ignoring
                    end repeat
                    if matchCount is 1 then
            \(selectBody("window matchIdx"))
                    else
                        return "FALLBACK"
                    end if
                end timeout
            end tell
            """
            if let raw = runScript(matchSource) {
                if raw != "FALLBACK" { return raw == "true" }
                // "FALLBACK" → title didn't uniquely match; use the raise path.
            } else {
                // Script errored (permission denied / timeout). Still bring the
                // row's window forward — AX raise + process activation work
                // without Automation and cost no spawn — but skip the second
                // osascript: re-spawning against a denied/wedged browser only
                // doubles the give-up latency for no gain.
                bringForward(window, app: app)
                return false
            }
        }

        // Fallback: raise the row's window frontmost, operate on `window 1`.
        raiseInBrowser(window, pid: app.processIdentifier)
        let source = """
        tell \(appLit)
            with timeout of 3 seconds
                if (count of windows) = 0 then return "false"
        \(selectBody("window 1"))
            end timeout
        end tell
        """
        guard let raw = runScript(source) else {
            // Same commit-must-do-something fallback as the match path above.
            bringForward(window, app: app)
            return false
        }
        return raw == "true"
    }

    /// Close the row window's browser tab at `tabIndex` (0-based here, 1-based for
    /// AppleScript) via Apple Events. Run off-main. Unlike `activateTab`, the
    /// preferred name-match path neither raises nor activates — closing a tab from
    /// the switcher must not steal focus or reorder the browser's windows; only
    /// the ambiguous-title fallback raises (the sole way to disambiguate the
    /// window), mirroring `activateTab`.
    static func closeTab(at tabIndex: Int, in app: NSRunningApplication, window: AXUIElement, title: String) -> Bool {
        // Sending an Apple Event to a quit app relaunches it — bail if terminated.
        guard !app.isTerminated,
              let family = Family.from(bundleID: app.bundleIdentifier),
              let bid = app.bundleIdentifier else { return false }
        let appLit = appLiteral(bid)
        let attr: String = (family == .safari) ? "name" : "title"
        let oneBased = tabIndex + 1

        // "close tab N of <windowExpr>" — same keyword in both dictionaries.
        func closeBody(_ windowExpr: String) -> String {
            """
                    set tabCount to count of tabs of \(windowExpr)
                    if \(oneBased) > tabCount then return "false"
                    close tab \(oneBased) of \(windowExpr)
                    return "true"
            """
        }

        // Preferred path: close within the name-matched window, no raise.
        if !title.isEmpty {
            let lit = escape(title)
            let matchSource = """
            tell \(appLit)
                with timeout of 3 seconds
                    set wc to count of windows
                    if wc = 0 then return "false"
                    set matchIdx to 0
                    set matchCount to 0
                    repeat with i from 1 to wc
                        ignoring white space
                            if (\(attr) of window i) is "\(lit)" then
                                set matchIdx to i
                                set matchCount to matchCount + 1
                            end if
                        end ignoring
                    end repeat
                    if matchCount is 1 then
            \(closeBody("window matchIdx"))
                    else
                        return "FALLBACK"
                    end if
                end timeout
            end tell
            """
            if let raw = runScript(matchSource) {
                if raw != "FALLBACK" { return raw == "true" }
                // "FALLBACK" → title didn't uniquely match; use the raise path.
            } else {
                // Script errored (permission/timeout) — don't double-spawn the
                // raise path, just report the failure.
                return false
            }
        }

        // Fallback: raise the row's window frontmost, operate on `window 1`.
        raiseInBrowser(window, pid: app.processIdentifier)
        let source = """
        tell \(appLit)
            with timeout of 3 seconds
                if (count of windows) = 0 then return "false"
        \(closeBody("window 1"))
            end timeout
        end tell
        """
        guard let raw = runScript(source) else { return false }
        return raw == "true"
    }
}
