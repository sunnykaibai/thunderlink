import CoreGraphics
import Testing
@testable import ThunderLink

struct InputStateTests {
    @Test func pressedMouseOrKeyPreventsSafeTransferUntilPhysicalRelease() {
        var state = InputState()
        state.observeButton(0, isDown: true)
        #expect(state.hasPressedInput)
        state.observeButton(0, isDown: false)
        #expect(!state.hasPressedInput)

        state.observeKey(12, kind: "down", flags: [])
        #expect(state.hasPressedInput)
        state.observeKey(12, kind: "up", flags: [])
        #expect(!state.hasPressedInput)
    }

    @Test func modifierFlagsAreTrackedAndReleased() {
        var state = InputState()
        state.observeKey(59, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1))
        state.observeKey(58, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | 0x21))
        #expect(state.pressedKeys == Set<CGKeyCode>([58, 59]))

        state.observeKey(59, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20))
        #expect(state.pressedKeys == Set<CGKeyCode>([58]))
        state.observeKey(58, kind: "flags", flags: [])
        #expect(!state.hasPressedInput)
    }

    @Test func releasingOneShiftDoesNotLeaveItsKeyStaleWhileOtherShiftIsHeld() {
        var state = InputState()
        state.observeKey(56, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2))
        state.observeKey(60, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x6))
        state.observeKey(56, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x4))
        #expect(state.pressedKeys == Set<CGKeyCode>([60]))
        state.observeKey(60, kind: "flags", flags: [])
        #expect(!state.hasPressedInput)
    }

    @Test func capsLockDoesNotCountAsAHeldKey() {
        var state = InputState()
        state.observeKey(57, kind: "flags", flags: [.maskAlphaShift])
        #expect(!state.hasPressedInput)
    }

    @Test func remoteKeysRemainSuppressedLocallyThroughRepeatAndPhysicalUp() {
        var state = InputState()
        state.observeKey(12, kind: "down", flags: [])
        state.suppressPressedInputUntilRelease()
        let repeatedDownWasSuppressed = state.observeKey(12, kind: "down", flags: [])
        #expect(repeatedDownWasSuppressed)
        let physicalUpWasSuppressed = state.observeKey(12, kind: "up", flags: [])
        #expect(physicalUpWasSuppressed)
        let nextDownWasSuppressed = state.observeKey(12, kind: "down", flags: [])
        #expect(!nextDownWasSuppressed)
    }

    @Test func pendingStopCanFinishOnlyAfterEveryRemoteInputIsPhysicallyReleased() {
        var state = InputState()
        state.observeKey(12, kind: "down", flags: [])
        state.observeButton(0, isDown: true)
        state.suppressPressedInputUntilRelease()
        #expect(state.hasSuppressedInput)

        let keyUpWasSuppressed = state.observeKey(12, kind: "up", flags: [])
        #expect(keyUpWasSuppressed)
        #expect(state.hasSuppressedInput)
        let buttonUpWasSuppressed = state.observeButton(0, isDown: false)
        #expect(buttonUpWasSuppressed)
        #expect(!state.hasSuppressedInput)
    }

    @Test func remoteMouseDragStaysSuppressedUntilPhysicalButtonUp() {
        var state = InputState()
        state.observeButton(1, isDown: true)
        state.suppressPressedInputUntilRelease()
        #expect(state.shouldSuppressDrag(button: 1))
        #expect(!state.shouldSuppressDrag(button: 0))

        let buttonUpWasSuppressed = state.observeButton(1, isDown: false)
        #expect(buttonUpWasSuppressed)
        #expect(!state.shouldSuppressDrag(button: 1))
    }

    @Test func restartDropsStaleStateButKeepsSuppressionForStillHeldInput() {
        var state = InputState()
        state.observeKey(12, kind: "down", flags: [])
        state.observeKey(13, kind: "down", flags: [])
        state.suppressPressedInputUntilRelease()

        var physical = InputState()
        physical.observeKey(13, kind: "down", flags: [])
        state.reconcilePhysicalState(with: physical)

        #expect(state.pressedKeys == Set<CGKeyCode>([13]))
        #expect(state.hasSuppressedInput)
        let keyUpWasSuppressed = state.observeKey(13, kind: "up", flags: [])
        #expect(keyUpWasSuppressed)
        #expect(!state.hasSuppressedInput)
    }

    @Test func transferDecisionChecksObservedFlagsAndPhysicalSnapshot() {
        let state = InputState()
        #expect(state.allowsTransfer(eventFlags: [], physicalInputPressed: false))
        #expect(!state.allowsTransfer(eventFlags: [.maskCommand], physicalInputPressed: false))
        #expect(!state.allowsTransfer(eventFlags: [], physicalInputPressed: true))
    }

    @Test func emergencyReleaseRequiresControlOptionEscape() {
        #expect(InputState.isEmergencyRelease(
            key: 53,
            kind: "down",
            flags: [.maskControl, .maskAlternate]
        ))
        #expect(!InputState.isEmergencyRelease(key: 53, kind: "up", flags: [.maskControl, .maskAlternate]))
        #expect(!InputState.isEmergencyRelease(key: 53, kind: "down", flags: [.maskControl]))
        #expect(!InputState.isEmergencyRelease(key: 12, kind: "down", flags: [.maskControl, .maskAlternate]))
    }

    @Test func malformedButtonAndKeyValuesCannotGrowTrackedState() {
        var state = InputState()
        for button in 32..<10_000 {
            state.observeButton(button, isDown: true)
        }
        for key in 256..<10_000 {
            state.observeKey(CGKeyCode(key), kind: "down", flags: [])
        }
        #expect(!state.hasPressedInput)
    }

    @Test func adjacentDisplayMakesSharedEdgeInternal() {
        let left = ActiveDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = ActiveDisplay(id: 2, bounds: CGRect(x: 100, y: 0, width: 100, height: 100))
        #expect(!DisplayGeometry.isOuterEdge(of: left, atY: 50, edge: .right, among: [left, right]))
        #expect(DisplayGeometry.isOuterEdge(of: left, atY: 50, edge: .left, among: [left, right]))
        #expect(DisplayGeometry.isOuterEdge(of: left, atY: 150, edge: .right, among: [left, right]))
    }
}
