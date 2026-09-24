import Testing

@testable import SigilApp

/// Every tab's screen stays in the view tree; only the visible one should breathe.
struct TerminalScreenTests {
    @Test func selectedWorkingTabPulses() {
        #expect(TerminalScreen.pulses(isWorking: true, isSelected: true, reduceMotion: false))
    }

    @Test func hiddenWorkingTabDoesNotPulse() {
        #expect(!TerminalScreen.pulses(isWorking: true, isSelected: false, reduceMotion: false))
    }

    @Test func idleTabDoesNotPulse() {
        #expect(!TerminalScreen.pulses(isWorking: false, isSelected: true, reduceMotion: false))
    }

    @Test func reducedMotionHoldsTheGlowSteady() {
        #expect(!TerminalScreen.pulses(isWorking: true, isSelected: true, reduceMotion: true))
    }
}
