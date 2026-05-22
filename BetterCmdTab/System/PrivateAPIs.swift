import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
import Darwin

/// Runtime-resolved bindings for Apple private APIs used to discover windows
/// that the public `kAXWindowsAttribute` query misses (e.g. fullscreen windows
/// living on their own Spaces) and to raise a specific window across Spaces.
/// dlsym-based so the Xcode project does not need an extra linker flag or
/// bridging header.
enum PrivateAPI {
    private static let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    private static func sym<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    // MARK: - HIServices (private)

    private static let axCreateWithRemoteTokenFn: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?)? =
        sym("_AXUIElementCreateWithRemoteToken", in: RTLD_DEFAULT_HANDLE)
    private static let axGetWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? =
        sym("_AXUIElementGetWindow", in: RTLD_DEFAULT_HANDLE)

    /// Build a remote-token AXUIElement for `(pid, axId)`. Token format is 20
    /// bytes: pid (Int32 LE) | 0 (Int32 LE) | 0x636f636f (Int32 LE) | axId (UInt64 LE).
    static func axElement(pid: pid_t, axId: UInt64) -> AXUIElement? {
        guard let fn = axCreateWithRemoteTokenFn else { return nil }
        var token = Data(count: 20)
        var pidVal = pid
        var zero: Int32 = 0
        var magic: Int32 = 0x636f636f
        var id = axId
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: &pidVal) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: &zero) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: &magic) { Data($0) })
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: &id) { Data($0) })
        return fn(token as CFData)?.takeRetainedValue()
    }

    /// AX → CGWindowID. Returns 0 on failure.
    static func cgWindowId(of element: AXUIElement) -> CGWindowID {
        guard let fn = axGetWindowFn else { return 0 }
        var id: CGWindowID = 0
        let err = fn(element, &id)
        return err == .success ? id : 0
    }

    // MARK: - SkyLight: cross-Space window raise

    private static let setFrontProcFn: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, Int32) -> CGError)? =
        sym("_SLPSSetFrontProcessWithOptions", in: skyLight)
    private static let postEventFn: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? =
        sym("SLPSPostEventRecordTo", in: skyLight)
    // GetProcessForPID is deprecated past macOS 10.9 and the Swift importer
    // hides it — pull the symbol via dlsym instead.
    private static let getProcessForPIDFn: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)? =
        sym("GetProcessForPID", in: RTLD_DEFAULT_HANDLE)

    /// One-shot startup diagnostic. Returns the list of dlsym symbols that
    /// failed to resolve, so AppDelegate can surface a single warning instead
    /// of every call site silently no-opping.
    static func selfCheck() -> [String] {
        var missing: [String] = []
        if axCreateWithRemoteTokenFn == nil { missing.append("_AXUIElementCreateWithRemoteToken") }
        if axGetWindowFn == nil { missing.append("_AXUIElementGetWindow") }
        if setFrontProcFn == nil { missing.append("_SLPSSetFrontProcessWithOptions") }
        if postEventFn == nil { missing.append("SLPSPostEventRecordTo") }
        if getProcessForPIDFn == nil { missing.append("GetProcessForPID") }
        return missing
    }

    /// Raise a specific window across Spaces (including a fullscreen window
    /// living on its own Space). The public `kAXRaiseAction` and
    /// `NSRunningApplication.activate()` cannot switch the user to a Space
    /// they're not on; SkyLight's private `_SLPSSetFrontProcessWithOptions` +
    /// `SLPSPostEventRecordTo` synthetic event do.
    ///
    /// Returns true when both SLPS calls dispatched successfully — the caller
    /// can then skip the `NSWorkspace.openApplication` fallback (which would
    /// otherwise race and reset focus to the app's last-active window rather
    /// than the one we just raised).
    @discardableResult
    static func raiseWindow(pid: pid_t, wid: CGWindowID) -> Bool {
        guard wid != 0 else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard let getPSN = getProcessForPIDFn, getPSN(pid, &psn) == noErr else { return false }
        guard let setFront = setFrontProcFn, let postEvent = postEventFn else { return false }

        // mode 2 = userGenerated — required for the Space switch to occur.
        let setErr = setFront(&psn, wid, 2)

        // Post a synthetic event so the window server promotes our raise
        // request. Without this, fullscreen windows often stay backgrounded.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x3a] = 0x80
        var widLE = wid
        withUnsafeBytes(of: &widLE) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        bytes[0x20] = 0x02
        let postErr = bytes.withUnsafeMutableBufferPointer { buf -> CGError in
            postEvent(&psn, buf.baseAddress!)
        }
        return setErr == .success && postErr == .success
    }
}
