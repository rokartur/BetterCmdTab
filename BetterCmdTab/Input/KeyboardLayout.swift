import Carbon.HIToolbox
import Foundation
import os

enum KeyboardHand {
    case left, right
}

/// Shared keycode → character translation for the current keyboard layout.
///
/// `HotkeyTap` does its own translation on the tap thread from a private cache;
/// this is a separate, thread-safe utility for the *other* consumer — the
/// secure-input Carbon-chord dispatch in `SwitcherController`, which resolves a
/// fired chord's keycode into the same letter/search character the tap would
/// have produced. The ~15 lines of `UCKeyTranslate` glue are intentionally
/// duplicated rather than shared out of `HotkeyTap`, to keep the hot-path tap
/// untouched (its cache is read on its own thread under its own lock); only
/// the cold-path layout *loading* is shared via
/// `currentOrFallbackLayoutData()`.
///
/// The layout snapshot is loaded lazily and refreshed on the system
/// input-source-changed notification, so a mid-session layout switch stays
/// correct.
enum KeyboardLayout {
    private static let layoutData = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private static let observerInstalled = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// The character that `keyCode` produces with no modifiers on the current
    /// layout, or `nil` if it isn't a producing key (e.g. a pure modifier).
    ///
    /// Generic over the integer width because each caller holds a keycode in
    /// whatever type its source hands over — a `CGKeyCode` from a layout scan, a
    /// `UInt32` from a Carbon chord. A virtual keycode is a `UInt16`, so a value
    /// that doesn't fit is not a key and answers `nil` instead of trapping the
    /// caller on a narrowing conversion.
    static func character(for keyCode: some BinaryInteger) -> Character? {
        guard let virtualKey = UInt16(exactly: keyCode) else { return nil }
        ensureLoaded()
        return translate(virtualKey, in: layoutData.withLock { $0 })
    }

    private static func translate(_ virtualKey: UInt16, in layout: Data?) -> Character? {
        guard let data = layout else { return nil }
        return data.withUnsafeBytes { raw -> Character? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            let maxLen = 4
            var chars = [UniChar](repeating: 0, count: maxLen)
            var actualLen = 0
            let status = UCKeyTranslate(
                base,
                virtualKey,
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

    /// The a–z letters the current layout puts under `hand`, by touch-typing key position.
    static func letters(under hand: KeyboardHand) -> Set<Character> {
        var letters = Set<Character>()
        for keyCode in hand == .left ? leftHandKeyCodes : rightHandKeyCodes {
            guard let ch = character(for: keyCode), ch.isASCII, ch.isLetter else { continue }
            letters.insert(Character(ch.lowercased()))
        }
        return letters
    }

    private static let leftHandKeyCodes = [
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T,
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B,
    ]
    // The punctuation keys carry letters on other layouts (AZERTY M, Dvorak S/Z).
    private static let rightHandKeyCodes = [
        kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_Semicolon, kVK_ANSI_Quote,
        kVK_ANSI_N, kVK_ANSI_M, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash,
    ]

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
        // Typical for IMEs without kTISPropertyUnicodeKeyLayoutData — fall back
        // to the most recently used ASCII-capable keyboard layout.
        if let data = asciiCapableLayoutData() {
            Log.hotkey.info("Current input source has no Unicode layout data — using ASCII-capable fallback")
            return data
        }
        Log.hotkey.warning("No Unicode layout data on current or ASCII-capable input source")
        return nil
    }

    /// The most recently used ASCII-capable keyboard layout, the current one when it is ASCII-capable.
    private static func asciiCapableLayoutData() -> Data? {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return layoutData(from: src)
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
