import AppKit
import Testing
@testable import BetterCmdTab

/// The settings window is now torn down on close (`SettingsWindowPresenter`
/// drops its `window`/`windowController` references when the window closes), so
/// RAM only returns to baseline if the view tree is free of retain cycles.
/// These verify each tab controller — where the views, gradient layers and
/// images that grow the footprint live — actually deallocates once released.
/// A `weak` reference that survives the `autoreleasepool` means a cycle leaked
/// the controller, which would keep the ~40MB resident after close.
@MainActor
@Suite("Settings lifecycle")
struct SettingsLifecycleTests {

    private func expectDeallocates<T: NSViewController>(_ make: () -> T) -> Bool {
        weak var weakVC: T?
        autoreleasepool {
            let vc = make()
            _ = vc.view // force loadView + viewDidLoad (builds the heavy subtree)
            weakVC = vc
        }
        return weakVC == nil
    }

    @Test("General tab controller deallocates when released")
    func general() { #expect(expectDeallocates { GeneralSettingsViewController() }) }

    @Test("Behavior tab controller deallocates when released")
    func behavior() { #expect(expectDeallocates { BehaviorSettingsViewController() }) }

    @Test("Apps tab controller deallocates when released")
    func apps() { #expect(expectDeallocates { AppsSettingsViewController() }) }

    @Test("Appearance tab controller deallocates when released")
    func appearance() { #expect(expectDeallocates { AppearanceSettingsViewController() }) }

    @Test("Experimental tab controller deallocates when released")
    func experimental() { #expect(expectDeallocates { ExperimentalSettingsViewController() }) }

    @Test("About tab controller deallocates when released")
    func about() { #expect(expectDeallocates { AboutSettingsViewController() }) }
}
