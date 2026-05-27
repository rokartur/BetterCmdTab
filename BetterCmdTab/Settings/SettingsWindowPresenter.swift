import AppKit
import BetterSettings

/// Presents the settings window, backed by the shared `BetterSettings` package
/// (macOS-style sidebar with section search). The public `show()` API is
/// unchanged so call sites in `AppDelegate` keep working.
@MainActor
final class SettingsWindowPresenter {

    static let shared = SettingsWindowPresenter()

    private var controller: SettingsWindowController?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    func show() {
        if controller == nil {
            createController()
        }
        controller?.show()
    }

    func hide() {
        controller?.window?.orderOut(nil)
    }

    private func createController() {
        let controller = SettingsWindowController(configuration: SettingsCatalog.makeConfiguration())
        self.controller = controller

        // Free the whole window tree (split view, sidebar, cached tab
        // controllers and their gradient layers/images) when the user closes
        // it, returning RAM to the pre-open baseline. `queue: .main` defers the
        // teardown until after AppKit's close sequence unwinds. `show()` lazily
        // rebuilds it on the next open.
        if let window = controller.window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.teardownAfterClose()
                }
            }
        }
    }

    private func teardownAfterClose() {
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
            closeObserver = nil
        }
        controller?.tearDownAndReleaseWindow()
        controller = nil
    }
}
