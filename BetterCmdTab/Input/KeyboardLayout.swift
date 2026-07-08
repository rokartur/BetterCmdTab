import Carbon.HIToolbox
import Foundation
import os

/// Shared keycode → character translation for the current keyboard layout.
///
/// `HotkeyTap` does its own translation on the tap thread from a private cache;
/// this is a separate, thread-safe utility for the *other* consumer — the
/// secure-input Carbon-chord dispatch in `SwitcherController`, which resolves a
/// fired chord's keycode into the same letter/search character the tap would
/// have produced. The ~15 lines of `UCKeyTranslate` glue are intentionally
/// duplicated rather than shared out of `HotkeyTap`, to keep the hot-path tap
/// untouched (its cache is read on its own thread under its own lock).
///
/// The layout snapshot is loaded lazily and refreshed on the system
/// input-source-changed notification, so a mid-session layout switch stays
/// correct.
enum KeyboardLayout {
    private static let layoutData = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private static let observerInstalled = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// The character that `keyCode` produces with no modifiers on the current
    /// layout, or `nil` if it isn't a producing key (e.g. a pure modifier).
    static func character(for keyCode: UInt16) -> Character? {
        ensureLoaded()
        guard let data = layoutData.withLock({ $0 }) else { return nil }
        return data.withUnsafeBytes { raw -> Character? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            let maxLen = 4
            var chars = [UniChar](repeating: 0, count: maxLen)
            var actualLen = 0
            let status = UCKeyTranslate(
                base,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                maxLen,
                &actualLen,
                &chars
            )
            guard status == noErr, actualLen > 0, let scalar = Unicode.Scalar(chars[0]) else { return nil }
            return Character(scalar)
        }
    }

    /// Re-read the current keyboard layout. Safe to call from any thread.
    static func reload() {
        guard let data = currentOrFallbackLayoutData() else { return }
        layoutData.withLock { $0 = data }
    }

    static func currentOrFallbackLayoutData() -> Data? {
        if let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let data = layoutData(from: src) {
            return data
        }
        if let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return layoutData(from: src)
        }
        return nil
    }

    private static func layoutData(from source: TISInputSource) -> Data? {
        guard let prop = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(prop).takeUnretainedValue() as Data
    }

    private static func ensureLoaded() {
        installObserverIfNeeded()
        if layoutData.withLock({ $0 == nil }) { reload() }
    }

    private static func installObserverIfNeeded() {
        let shouldInstall = observerInstalled.withLock { installed -> Bool in
            if installed { return false }
            installed = true
            return true
        }
        guard shouldInstall else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in reload() }
    }
}
