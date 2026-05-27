import BetterSettings

/// Presents the settings window. Lifecycle (lazy creation, activation,
/// free-on-close, robust reopen) is owned by `BetterSettings.SettingsPresenter`;
/// this just wires the catalog and keeps the existing `show()` call sites working.
@MainActor
final class SettingsWindowPresenter {

    static let shared = SettingsWindowPresenter()

    private let presenter = SettingsPresenter(closeBehavior: .releaseOnClose) {
        SettingsCatalog.makeConfiguration()
    }

    private init() {}

    func show() {
        presenter.show()
    }

    func hide() {
        presenter.hide()
    }
}
