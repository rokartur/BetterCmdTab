#if DEBUG
import AppKit
import BetterSettings
import os

/// Debug-only pane: overrides the app language through the app-domain
/// `AppleLanguages` default, leaving the macOS language untouched. Strings are
/// not localized on purpose; Release never builds this file's contents.
@MainActor
final class DebugSettingsViewController: SettingsTabViewController {

    private let languagePopup = NSPopUpButton()
    private let languageCodes = Bundle.main.localizations.filter { $0 != "Base" }.sorted()

    override func setupContent() {
        let languageTitles = languageCodes.map { code in
            let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            return "\(name) (\(code))"
        }
        configurePopup(languagePopup, titles: ["System"] + languageTitles, action: #selector(languageChanged))

        let language = addSection(title: "Language")
        addRow(
            to: language,
            title: "App language",
            subtitle: "Overrides the macOS language for this app only. Relaunches the app.",
            accessory: languagePopup
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let code = Self.overriddenLanguage, let index = languageCodes.firstIndex(of: code) {
            languagePopup.selectItem(at: index + 1)
        } else {
            languagePopup.selectItem(at: 0)
        }
    }

    /// Reads the app domain only: `UserDefaults.standard` would fall through to
    /// the global `AppleLanguages` and always report an override.
    private static var overriddenLanguage: String? {
        let appDomain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!)
        return (appDomain?["AppleLanguages"] as? [String])?.first
    }

    @objc private func languageChanged() {
        let index = languagePopup.indexOfSelectedItem
        let code = index == 0 ? nil : languageCodes[index - 1]
        guard code != Self.overriddenLanguage else { return }

        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        relaunch()
    }

    /// Bundle localizations are resolved once per launch, so the new language
    /// needs a fresh process. The shell waits for this pid to exit first, so two
    /// instances never hold the ⌘Tab event tap at once.
    private func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; open \"$2\"",
            "sh", String(getpid()), Bundle.main.bundlePath,
        ]
        do {
            try relauncher.run()
        } catch {
            Log.ui.error("Language relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}
#endif
