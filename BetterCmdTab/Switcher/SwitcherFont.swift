import AppKit

/// Resolves the switcher's name/title font for the user's chosen face (#62).
/// Non-system designs go through an `NSFontDescriptor.withDesign` resolve,
/// which is memoized so it runs once per (size, weight, face) — never per row
/// apply on the reveal path. Jump letters and count badges keep their
/// dedicated system/monospaced fonts and never come through here.
@MainActor
enum SwitcherFont {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
        let design: SwitcherFontFace
    }

    private static var cache: [Key: NSFont] = [:]
    /// Small hard cap: a session touches a handful of (size, weight) pairs per
    /// face; overflow just clears (next lookups re-resolve and re-fill).
    private static let cacheLimit = 64

    static func font(ofSize size: CGFloat, weight: NSFont.Weight, design: SwitcherFontFace) -> NSFont {
        guard design != .system else { return .systemFont(ofSize: size, weight: weight) }
        let key = Key(size: size, weight: weight, design: design)
        if let cached = cache[key] { return cached }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let resolved = system.fontDescriptor.withDesign(design.systemDesign)
            .flatMap { NSFont(descriptor: $0, size: size) } ?? system
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = resolved
        return resolved
    }
}
