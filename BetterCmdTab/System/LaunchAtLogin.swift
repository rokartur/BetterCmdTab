import Foundation
import Combine
import ServiceManagement
import os

@MainActor
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled: Bool

    private let service = SMAppService.mainApp

    private init() {
        isEnabled = service.status == .enabled
    }

    func refresh() {
        let value = service.status == .enabled
        if isEnabled != value { isEnabled = value }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else {
                    try service.register()
                }
            } else {
                try service.unregister()
            }
        } catch {
            Log.launch.error("Failed to \(enabled ? "register" : "unregister", privacy: .public) launch-at-login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
