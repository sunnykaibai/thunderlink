import CoreGraphics
import Testing
@testable import ThunderLink

struct RemoteClicksTests {
    @Test func leftAndRightTypesAreAuthoritative() throws {
        var clicks = RemoteClicks()
        let misleadingLeft = event(type: .leftMouseDown, button: 1, count: 1)
        let misleadingRight = event(type: .rightMouseDown, button: 0, count: 1)

        #expect(try message(&clicks, .leftMouseDown, misleadingLeft).button == 0)
        #expect(try message(&clicks, .rightMouseDown, misleadingRight).button == 1)
    }

    @Test func otherButtonsRequireTheirSupportedHardwareNumber() throws {
        var clicks = RemoteClicks()
        let valid = event(type: .otherMouseDown, button: 2, count: 1)
        #expect(try message(&clicks, .otherMouseDown, valid).button == 2)
        #expect(clicks.message(
            type: .otherMouseDown,
            event: event(type: .otherMouseDown, button: 1, count: 1)
        ) == nil)
        #expect(clicks.message(
            type: .otherMouseUp,
            event: event(type: .otherMouseUp, button: 32, count: 1)
        ) == nil)
    }

    @Test func inheritedLocalCountIsRebasedAndItsUpUsesThePairedCount() throws {
        var clicks = RemoteClicks()
        let down = try message(
            &clicks, .leftMouseDown,
            event(type: .leftMouseDown, button: 0, count: 2)
        )
        let up = try message(
            &clicks, .leftMouseUp,
            event(type: .leftMouseUp, button: 0, count: 0)
        )

        #expect(down.clickCount == 1)
        #expect(up.clickCount == 1)
        #expect(up.eventKind == "up")
    }

    @Test func genuineDoubleAndTripleClickContinueForTheSameButton() throws {
        var clicks = RemoteClicks()
        var forwarded: [Int] = []
        for hardwareCount in 1...3 {
            let down = try message(
                &clicks, .leftMouseDown,
                event(type: .leftMouseDown, button: 0, count: Int64(hardwareCount))
            )
            let up = try message(
                &clicks, .leftMouseUp,
                event(type: .leftMouseUp, button: 0, count: Int64(hardwareCount))
            )
            forwarded.append(down.clickCount ?? 0)
            #expect(up.clickCount == down.clickCount)
        }
        #expect(forwarded == [1, 2, 3])
    }

    @Test func buttonChangeAndAppreciableMovementStartANewSequence() throws {
        var clicks = RemoteClicks()
        _ = clicks.message(
            type: .leftMouseDown,
            event: event(type: .leftMouseDown, button: 0, count: 1)
        )
        _ = clicks.message(
            type: .leftMouseUp,
            event: event(type: .leftMouseUp, button: 0, count: 1)
        )

        let right = try message(
            &clicks, .rightMouseDown,
            event(type: .rightMouseDown, button: 1, count: 2)
        )
        #expect(right.clickCount == 1)

        clicks = RemoteClicks()
        _ = clicks.message(
            type: .leftMouseDown,
            event: event(type: .leftMouseDown, button: 0, count: 1)
        )
        _ = clicks.message(
            type: .leftMouseUp,
            event: event(type: .leftMouseUp, button: 0, count: 1)
        )
        clicks.move(dx: 3, dy: 3)
        clicks.move(dx: -3, dy: -3)
        let moved = try message(
            &clicks, .leftMouseDown,
            event(type: .leftMouseDown, button: 0, count: 2)
        )
        #expect(moved.clickCount == 1)
    }

    @Test func trackpadJitterDoesNotBreakADoubleClick() throws {
        var clicks = RemoteClicks()
        _ = clicks.message(
            type: .leftMouseDown,
            event: event(type: .leftMouseDown, button: 0, count: 1)
        )
        _ = clicks.message(
            type: .leftMouseUp,
            event: event(type: .leftMouseUp, button: 0, count: 1)
        )
        clicks.move(dx: 1, dy: 1)
        let second = try message(
            &clicks, .leftMouseDown,
            event(type: .leftMouseDown, button: 0, count: 2)
        )
        #expect(second.clickCount == 2)
    }

    @Test func repeatedDownWithoutAnUpDoesNotInventADoubleClick() throws {
        var clicks = RemoteClicks()
        _ = clicks.message(
            type: .leftMouseDown,
            event: event(type: .leftMouseDown, button: 0, count: 1)
        )
        let repeated = try message(
            &clicks, .leftMouseDown,
            event(type: .leftMouseDown, button: 0, count: 2)
        )
        #expect(repeated.clickCount == 1)
    }

    @Test func onlyKeyboardModifierFlagsAndSideBitsCrossTheWire() throws {
        var clicks = RemoteClicks()
        let rawFlags = CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskShift.rawValue
            | 0x0000_0001
            | 0x0000_0004
            | CGEventFlags.maskNonCoalesced.rawValue
        let hardware = event(type: .leftMouseDown, button: 0, count: 1)
        hardware.flags = CGEventFlags(rawValue: rawFlags)

        let wireMessage = try message(&clicks, .leftMouseDown, hardware)
        #expect(wireMessage.flags == rawFlags & ~CGEventFlags.maskNonCoalesced.rawValue)
    }

    @Test func unmatchedUpIsStillForwardedWithSafeMetadata() throws {
        var clicks = RemoteClicks()
        let up = try message(
            &clicks, .leftMouseUp,
            event(type: .leftMouseUp, button: 7, count: Int64.max)
        )
        #expect(up.button == 0)
        #expect(up.eventKind == "up")
        #expect(up.clickCount == 1)
    }

    private func event(type: CGEventType, button: Int64, count: Int64) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        event.setIntegerValueField(.mouseEventClickState, value: count)
        return event
    }

    private func message(
        _ clicks: inout RemoteClicks,
        _ type: CGEventType,
        _ event: CGEvent
    ) throws -> WireMessage {
        let result = clicks.message(type: type, event: event)
        return try #require(result)
    }
}
