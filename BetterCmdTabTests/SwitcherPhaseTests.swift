import CoreGraphics
import Foundation
import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the fast-tap rescue: when the ⌘-release was dropped by
/// the tap (it gates `.releaseCmd` on `isSwitchingNow()`, set only once the main
/// thread reaches `.primed`), the controller re-reads the live modifier state and
/// commits instead of stranding the panel. This isolates the "release already
/// missed?" decision from the impure `CGEventSource` read.
@Suite("Switcher fast-tap rescue")
struct SwitcherReleaseMissedTests {
    @Test func missed_whenNeitherHoldModifierDown() {
        // ⌘Tab / ⌘` defaults: both triggers use Command. No modifier down → the
        // user already let go, so the release was missed and we must commit.
        #expect(SwitcherController.releaseAlreadyMissed(flags: [], appMask: .maskCommand, windowMask: .maskCommand))
    }

    @Test func notMissed_whileHoldModifierStillDown() {
        // ⌘ still physically held → normal hold-to-browse, reveal the panel.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: .maskCommand, windowMask: .maskCommand))
        // Extra modifiers alongside the hold modifier don't count as released.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskCommand, .maskShift], appMask: .maskCommand, windowMask: .maskCommand))
    }

    @Test func notMissed_whenEitherTriggerModifierDown() {
        // Distinct app/window hold modifiers (e.g. ⌘ for apps, ⌥ for windows):
        // either one still down means the switch is live.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskAlternate], appMask: .maskCommand, windowMask: .maskAlternate))
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: .maskCommand, windowMask: .maskAlternate))
        // Neither of the two trigger modifiers down → missed (a stray Shift is not
        // a hold modifier).
        #expect(SwitcherController.releaseAlreadyMissed(flags: [.maskShift], appMask: .maskCommand, windowMask: .maskAlternate))
    }

    @Test func disabledTrigger_contributesNoHold() {
        // A cleared shortcut passes a nil mask: it must never count as held, so an
        // incidentally-held ⌘ can't mask the real (Control) window hold modifier.
        #expect(SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: nil, windowMask: .maskControl))
        // The live window modifier still down → not missed.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskControl], appMask: nil, windowMask: .maskControl))
        // Both triggers disabled → nothing to hold, so the release is always missed.
        #expect(SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: nil, windowMask: nil))
    }
}

@Suite("Scoped modifier release gate")
struct SwitcherScopedModifierReleaseTests {
    @Test func releasesOnlyAfterTheActiveModifierIsUp() {
        #expect(!SwitcherController.activeModifierReleased(
            flags: [.maskAlternate, .maskShift], mask: .maskAlternate))
        #expect(SwitcherController.activeModifierReleased(
            flags: .maskShift, mask: .maskAlternate))
        #expect(SwitcherController.activeModifierReleased(
            flags: .maskCommand, mask: .maskAlternate))
    }

    @Test func requiresEveryModifierInACombinedTrigger() {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate]
        #expect(!SwitcherController.activeModifierReleased(flags: mask, mask: mask))
        #expect(SwitcherController.activeModifierReleased(flags: .maskCommand, mask: mask))
    }

    @Test func scopedOpensSkipTheLeadingCurrentWindow() {
        // Frontmost's window leads the scoped rows → start one past it so a
        // tap-release switches instead of re-activating the current window.
        #expect(SwitcherController.scopedInitialIndex(firstRowPid: 7, frontPid: 7, count: 3) == 1)
        // Scope excludes the frontmost app → its top row is already the target.
        #expect(SwitcherController.scopedInitialIndex(firstRowPid: 9, frontPid: 7, count: 3) == 0)
        // A single row can't be skipped past; unknown pids anchor at the top.
        #expect(SwitcherController.scopedInitialIndex(firstRowPid: 7, frontPid: 7, count: 1) == 0)
        #expect(SwitcherController.scopedInitialIndex(firstRowPid: nil, frontPid: nil, count: 3) == 0)
    }

    @Test func scopedOpensNeverTakeThePrimedMissedReleaseCommit() {
        // A core ⌘Tab chord whose ⌘-release was dropped during the primed delay
        // commits the primed pick outright — that pick is correct there.
        #expect(SwitcherController.shouldCommitPrimedOnMissedRelease(
            primedByHeldChord: true, scopedChord: false, quickReleaseParksSticky: false))
        // A scoped profile chord must NOT (#130): the primed pick comes from the
        // unscoped app list at index 0 — the frontmost app — so it would re-activate
        // the app the user is already on and read as a dead hotkey. Present instead
        // and let the visible release backstop commit the scope-filtered row.
        #expect(!SwitcherController.shouldCommitPrimedOnMissedRelease(
            primedByHeldChord: true, scopedChord: true, quickReleaseParksSticky: false))
        // Gesture opens hold no modifier; quick-tap stay-open parks instead.
        #expect(!SwitcherController.shouldCommitPrimedOnMissedRelease(
            primedByHeldChord: false, scopedChord: false, quickReleaseParksSticky: false))
        #expect(!SwitcherController.shouldCommitPrimedOnMissedRelease(
            primedByHeldChord: true, scopedChord: false, quickReleaseParksSticky: true))
    }
}

/// Pure-logic coverage for the `.visible` release-to-commit liveness backstop —
/// the recovery the prior #16 fixes lacked. A keyboard ⌘Tab panel closes on the
/// tap's single ⌘-release `flagsChanged`; if that event is dropped the panel
/// welds into `.visible` and the tap keeps swallowing ⌘W/⌘Q. The backstop polls
/// the live modifier and commits a missed release — but only for a panel where
/// releasing ⌘ would actually commit, and never when `HoldModifierMonitor`
/// already owns the release under Secure Event Input. These pin that arming
/// matrix so it can't silently widen (perpetual poll) or narrow (re-strand).
@Suite("Switcher visible-release backstop")
struct SwitcherVisibleReleaseBackstopTests {
    /// Helper with the common-case defaults: a live keyboard ⌘Tab panel.
    private func arm(
        phase: SwitcherController.Phase = .visible,
        primedByHeldChord: Bool = true,
        stickyOpen: Bool = false,
        tabDrillActive: Bool = false,
        secureInputActive: Bool = false
    ) -> Bool {
        SwitcherController.shouldArmVisibleReleaseBackstop(
            phase: phase,
            primedByHeldChord: primedByHeldChord,
            stickyOpen: stickyOpen,
            tabDrillActive: tabDrillActive,
            secureInputActive: secureInputActive
        )
    }

    @Test func arms_forLiveKeyboardPanel() {
        // The primary issue #16 case: a held-chord ⌘Tab panel on screen under
        // normal input — releasing ⌘ commits, so the backstop must guard it.
        #expect(arm())
    }

    @Test func off_whenNotVisible() {
        // Closed (the ~99.99% case) and panel-less `.primed` (owned by
        // primedWatchdog) schedule no timer.
        #expect(!arm(phase: .idle))
        #expect(!arm(phase: .primed))
    }

    @Test func off_forGestureOpens() {
        // Gesture opens carry `primedByHeldChord == false`: they are sticky and
        // never commit on release, so the backstop must stay off.
        #expect(!arm(primedByHeldChord: false))
    }

    @Test func off_whenParkedSticky() {
        // Mouse detach / stay-open search parks the panel (`stickyOpen`): releasing
        // ⌘ no longer commits, so polling would only waste wakes.
        #expect(!arm(stickyOpen: true))
    }

    @Test func on_whenDrilledIntoTabStrip() {
        // Tab drill-in forces `stickyOpen` true but STILL commits the highlighted
        // tab on release — so a dropped release there must be recovered too. This
        // is the gap a naive `!stickyOpen` gate would leave open.
        #expect(arm(stickyOpen: true, tabDrillActive: true))
    }

    @Test func arms_underSecureInput_forFlagsStateIndependentRecovery() {
        // Secure input is intentionally NOT excluded (issue #16): HoldModifierMonitor's
        // release poll reads the same CGEventSource.flagsState that can stick reporting
        // ⌘-held, so the backstop must also run under secure input to drive the
        // flagsState-independent no-interaction force-close.
        #expect(arm(secureInputActive: true))
        #expect(arm(stickyOpen: true, tabDrillActive: true, secureInputActive: true))
        // Sticky-without-drill still never arms, secure input or not.
        #expect(!arm(stickyOpen: true, secureInputActive: true))
    }

    @Test func drivesTapWeldHealFlag_heldChordOnly() {
        // This same predicate is the single source of truth for the tap's
        // `modifierHeldPanelFlag` weld self-heal (issue #16): on a live keyDown the
        // tap refuses to swallow an action key / letter-jump when the panel is
        // held-chord (flag true) AND the event's flags show the hold modifier up,
        // tearing the welded panel down instead. So the flag must be true exactly
        // for a held-chord panel (heal-eligible) and false for a deliberate stay-open
        // / gesture park, where bare keys must keep routing to the panel. Scoped
        // chords use this backstop but bypass the tap's core-only weld detector.
        #expect(arm())                          // held-chord ⌘Tab → heal-eligible
        #expect(!arm(stickyOpen: true))         // parked stay-open → bare keys route
        #expect(!arm(primedByHeldChord: false)) // gesture → bare keys route
    }
}

/// The backstop's no-interaction force-close is a flagsState-independent escape from
/// a panel welded open by a STUCK `CGEventSource.flagsState`. That stick only happens
/// under Secure Event Input (the tap is deaf and HoldModifierMonitor polls the same
/// lying state). Under NORMAL input flagsState is authoritative and the fast path
/// recovers any dropped release, so a held ⌘ must keep the panel open indefinitely —
/// force-closing it stranded a user holding ⌘ while reading the panel (issue: ⌘Tab
/// hold + idle closed after 4s). These pin the gate to secure input only.
@Suite("Switcher stranded-visible force-close")
struct SwitcherStrandedVisibleTests {
    private let ceiling: TimeInterval = 4

    @Test func neverForceClosesUnderNormalInputWithoutRecentFlap() {
        // The reported bug: ⌘ genuinely held, no steering, and no recent SEI flap —
        // normal input must NEVER force-close, no matter how long the panel idles.
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: false, idle: 0))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: false, idle: ceiling + 1))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: false, idle: 3600))
    }

    @Test func forceClosesPastCeilingUnderSecureInput() {
        // Secure input + idle beyond the ceiling: the only flagsState-independent
        // heal for a welded-open panel (issue #16).
        #expect(SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: ceiling + 0.5))
    }

    @Test func holdsBelowCeilingUnderSecureInput() {
        // Within the ceiling, even under secure input, a recently-steered panel is
        // left alone — the stamp is fresh, so don't yank it.
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: 0))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: ceiling - 0.5))
        // Boundary: exactly at the ceiling is not yet past it (strict `>`).
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: ceiling))
    }

    @Test func forceClosesPastCeilingWithinPostSecureWindow() {
        // The residual #16 gap: SEI has flapped OFF (secureInputActive false) but a
        // ⌘-held flagsState latch can outlive the SEI→OFF edge, so the bounded
        // post-SEI window must still force-close a stranded panel past the ceiling
        // even with secure input reported off.
        #expect(SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: true, idle: ceiling + 0.5))
    }

    @Test func holdsBelowCeilingWithinPostSecureWindow() {
        // The post-SEI window still respects the idle ceiling — a freshly-steered
        // panel right after a flap is not yanked before it goes quiet.
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: true, idle: ceiling - 0.5))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: true, idle: ceiling))
    }
}

/// A fast ⌘⇥ tap commits without ever showing the panel, so it must elect the
/// same row the panel would. While the list collapses to one row per app and
/// "Move minimized windows to the bottom" is on, `collapseToApplications` elects
/// the app's first *visible* window, because per-app window recency can still put
/// a just-minimized window at the head of the run — a same-pid run can straddle
/// the bucket boundary, and `.alphabetical` / `.launchOrder` make an app's rows
/// contiguous across buckets outright. Committing that row would un-minimize a
/// window the user deliberately put away. With the preference off the user asked
/// for pure recency, so the minimized leader stands (#159).
@Suite("Quick-tap visible-window election (#159)")
struct PrimedTargetIndexTests {
    /// The panel (`keptApplicationIndices`) and the fast tap (`primedTargetIndex`)
    /// are two independent implementations of one election rule, and
    /// `primedAppTargetRow`'s doc claims they agree. Pin that: drift is invisible
    /// at runtime — the panel would display one window while a quick tap raised
    /// another, and only the tap path un-minimizes. Proven for placeholder-free
    /// input only, which is all production feeds these paths (the sole placeholder
    /// is the never-minimized prewarm row).
    @Test("a quick tap elects the same row the panel collapses to", arguments: [true, false])
    func quickTapMatchesPanelElection(preferVisible: Bool) {
        let vectors: [(pids: [pid_t?], minimized: [Bool])] = [
            ([7, 9, 7], [true, false, false]),                  // minimized leader, visible later
            ([7, 7, 9, 9], [false, false, true, false]),        // slot ≠ row index after a collapse
            ([7, 7], [true, true]),                             // all-minimized fallback
            ([7, 9, 7, 9, 7], [true, true, true, false, false]),// interleaved, both apps upgrade
            ([nil, 4, 4], [false, true, false]),                // pid-less row in front
        ]
        for (pids, minimized) in vectors {
            let kept = CatalogFilter.keptApplicationIndices(
                pids: pids,
                placeholders: Array(repeating: false, count: pids.count),
                minimized: minimized,
                preferVisible: preferVisible)
            for pid in Set(pids.compactMap { $0 }) {
                let panelElected = kept.first { pids[$0] == pid }
                let tapElected = SwitcherController.primedTargetIndex(
                    count: pids.count,
                    preferVisible: preferVisible,
                    eligible: { pids[$0] == pid },
                    isMinimized: { minimized[$0] })
                #expect(panelElected == tapElected,
                        "pid \(pid) diverged for \(pids)/\(minimized) preferVisible=\(preferVisible)")
            }
        }
    }
}
