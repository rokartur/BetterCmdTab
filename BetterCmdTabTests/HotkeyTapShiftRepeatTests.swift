import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the held-Shift backward auto-repeat cadence (the
/// modifier-key counterpart to a held Tab). `repeatCadence` turns the global
/// 1/60 s key-repeat ticks into seconds, falls back to the macOS defaults when
/// unset, reports the system-wide "Off" state as `nil`, and clamps so a
/// misconfigured value can't spin a runaway timer.
@Suite("Hotkey tap shift-repeat cadence")
struct HotkeyTapShiftRepeatTests {

    @Test("unset ticks fall back to the macOS defaults")
    func defaultsWhenUnset() throws {
        let c = try #require(HotkeyTap.repeatCadence(initialTicks: 0, repeatTicks: 0))
        #expect(c.initial == 25.0 / 60.0)
        #expect(c.interval == 6.0 / 60.0)
    }

    @Test("custom ticks convert from 1/60 s to seconds")
    func convertsTicksToSeconds() throws {
        let c = try #require(HotkeyTap.repeatCadence(initialTicks: 15, repeatTicks: 2))
        #expect(c.initial == 15.0 / 60.0)
        #expect(c.interval == 2.0 / 60.0)
    }

    @Test("key repeat switched off (huge ticks) disables auto-repeat")
    func offWhenRepeatHuge() {
        #expect(HotkeyTap.repeatCadence(initialTicks: 25, repeatTicks: 300_000) == nil)
        // The threshold itself is treated as "Off".
        #expect(HotkeyTap.repeatCadence(initialTicks: 25, repeatTicks: 300) == nil)
    }

    @Test("tiny ticks are clamped so the timer can't run away")
    func clampsTinyValues() throws {
        let c = try #require(HotkeyTap.repeatCadence(initialTicks: 1, repeatTicks: 1))
        #expect(c.initial == 0.05)
        #expect(c.interval == 0.02)
    }
}
