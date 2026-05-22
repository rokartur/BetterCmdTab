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
}
