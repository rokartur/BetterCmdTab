import Foundation
import os

enum Log {
    private static let subsystem = "pro.bettercmdtab.BetterCmdTab"

    static let switcher = Logger(subsystem: subsystem, category: "switcher")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let mru = Logger(subsystem: subsystem, category: "mru")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let activator = Logger(subsystem: subsystem, category: "activator")
    static let priv = Logger(subsystem: subsystem, category: "private-api")
    static let launch = Logger(subsystem: subsystem, category: "launch-at-login")
    /// Temporary diagnostics for the "panel invisible on another Space after a
    /// full-screen app quits" report (#46). Capture with:
    ///   log stream --predicate 'subsystem == "pro.bettercmdtab.BetterCmdTab" AND category == "space-diag"' --info
    static let spaceDiag = Logger(subsystem: subsystem, category: "space-diag")

    /// Points-of-Interest signposter for the ⌘Tab reveal hot path. Use to capture
    /// where the panel-appearance latency goes in Instruments (Points of Interest
    /// instrument, subsystem above): timer-fire→visible, the catalog/configure
    /// work, and `panel.present()` split into its autolayout pass vs the
    /// WindowServer order-front. Near-zero cost when nothing is recording.
    static let reveal = OSSignposter(subsystem: subsystem, category: "reveal")
}
