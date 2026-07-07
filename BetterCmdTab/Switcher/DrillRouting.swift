import Foundation

/// Pure routing decisions for the window drill-down (#80), split from
/// `SwitcherController` so the unit suite can pin them without a live panel.
enum DrillRouting {
    /// Whether a `↓` keypress should open the window drill instead of
    /// navigating. Down stays navigation wherever it already moves the
    /// selection somewhere new: the list layout (column wrap,
    /// `wrapWithinColumn`) and multi-row grids (2-D neighbor moves). Only
    /// where it was a redundant linear wrap — a single-row grid or previews
    /// strip — does it drill, matching the native ⌘Tab `↓` gesture. Search
    /// owns the arrows while active, and a strip that is already up keeps
    /// them for its own navigation.
    static func downArrowOpensWindowDrill(layoutMode: SwitcherLayoutMode, rowsPerColumn: Int, searchActive: Bool, tabDrillActive: Bool) -> Bool {
        guard !searchActive, !tabDrillActive else { return false }
        guard layoutMode != .list else { return false }
        return rowsPerColumn <= 1
    }

    /// Strip cell title for a window row — the window title, or the app name
    /// when the window is untitled (an empty strip cell would be unclickable).
    static func stripTitle(windowTitle: String, appName: String) -> String {
        windowTitle.isEmpty ? appName : windowTitle
    }
}
