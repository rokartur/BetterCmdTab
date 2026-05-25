import AppKit

/// Optional sensory feedback played the moment the switcher commits a
/// selection. Both channels are off by default and read live from Preferences,
/// so toggling them takes effect on the next commit without a restart.
@MainActor
enum CommitFeedback {
    /// Cached so we don't re-decode the sound file on every commit. The system
    /// sound is loaded by name from the standard library locations.
    private static let clickSound: NSSound? = NSSound(named: NSSound.Name("Tink"))

    static func play() {
        let prefs = Preferences.shared

        if prefs.hapticOnCommit {
            // `.alignment` is the lightest of the three patterns — a single soft
            // tap. No-op on hardware without a Force Touch trackpad.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }

        if prefs.soundOnCommit, let sound = clickSound {
            // Restart from the top if a previous click is still ringing out so
            // rapid commits each get a tick instead of being swallowed.
            if sound.isPlaying { sound.stop() }
            sound.play()
        }
    }
}
