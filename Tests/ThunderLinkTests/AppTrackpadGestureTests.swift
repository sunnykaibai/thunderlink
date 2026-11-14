import CoreGraphics
import Foundation
import Testing
@testable import ThunderLink

struct AppTrackpadGestureTests {
    @Test func magnifyAndRotationRoundTripOnlyTheirAllowlistedFields() throws {
        let magnify = gesture(hidType: 8, phase: 2, field: 113, amount: 0.125)
        let capturedMagnify = try #require(AppTrackpadGesture(capturing: magnify))
        let rebuiltMagnify = try #require(capturedMagnify.makeEvent(at: CGPoint(x: 17, y: 23)))

        #expect(rebuiltMagnify.type.rawValue == 29)
        #expect(rebuiltMagnify.location == CGPoint(x: 17, y: 23))
        #expect(rebuiltMagnify.getIntegerValueField(rawField(110)) == 8)
        #expect(rebuiltMagnify.getIntegerValueField(rawField(132)) == 2)
        #expect(rebuiltMagnify.getDoubleValueField(rawField(113)) == 0.125)
        #expect(AppTrackpadGesture(capturing: rebuiltMagnify) == capturedMagnify)

        let rotation = gesture(hidType: 5, phase: 1, field: 114, amount: -12.5)
        let capturedRotation = try #require(AppTrackpadGesture(capturing: rotation))
        let rebuiltRotation = try #require(capturedRotation.makeEvent(at: .zero))
        #expect(rebuiltRotation.getIntegerValueField(rawField(110)) == 5)
        #expect(rebuiltRotation.getDoubleValueField(rawField(114)) == -12.5)
        #expect(AppTrackpadGesture(capturing: rebuiltRotation) == capturedRotation)
    }

    @Test func smartMagnifyAndNavigationSwipeUseOnlyVerifiedEncodings() throws {
        let smart = gesture(hidType: 22)
        let capturedSmart = try #require(AppTrackpadGesture(capturing: smart))
        #expect(capturedSmart.kind == .smartMagnify)
        #expect(AppTrackpadGesture(capturing: capturedSmart.makeEvent(at: .zero)!) == capturedSmart)

        let began = gesture(hidType: 16, phase: 1, integerField: 115, integerValue: 4)
        let capturedBegan = try #require(AppTrackpadGesture(capturing: began))
        #expect(capturedBegan.swipeDirection == .left)
        let ended = gesture(hidType: 16, phase: 4, integerField: 115, integerValue: 0)
        let capturedEnded = try #require(AppTrackpadGesture(capturing: ended))
        #expect(capturedEnded.swipeDirection == nil)
        #expect(AppTrackpadGesture(capturing: capturedEnded.makeEvent(at: .zero)!) == capturedEnded)
    }

    @Test func unsupportedAndMalformedEventsAreRejected() {
        let ordinary = CGEvent(source: nil)!
        ordinary.type = .mouseMoved
        #expect(AppTrackpadGesture(capturing: ordinary) == nil)

        #expect(AppTrackpadGesture(capturing: gesture(hidType: 6, phase: 2)) == nil)
        #expect(AppTrackpadGesture(capturing: gesture(hidType: 23, phase: 1)) == nil)
        #expect(AppTrackpadGesture(capturing: gesture(hidType: 8, phase: 16, field: 113, amount: 1)) == nil)
        #expect(AppTrackpadGesture(capturing: gesture(hidType: 5, phase: 2, field: 114, amount: .infinity)) == nil)

        let beginWrapper = CGEvent(source: nil)!
        beginWrapper.type = CGEventType(rawValue: 19)!
        #expect(AppTrackpadGesture(capturing: beginWrapper) == nil)
        let endWrapper = CGEvent(source: nil)!
        endWrapper.type = CGEventType(rawValue: 20)!
        #expect(AppTrackpadGesture(capturing: endWrapper) == nil)
    }

    @Test func codableRoundTripValidatesTheBoundedWireShape() throws {
        let original = try #require(AppTrackpadGesture(capturing: gesture(
            hidType: 8,
            phase: 2,
            field: 113,
            amount: 0.25
        )))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AppTrackpadGesture.self, from: data) == original)

        let malformed = Data(#"{"kind":"magnify","phase":2,"amount":1000}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppTrackpadGesture.self, from: malformed)
        }
    }

    private func gesture(
        hidType: Int64,
        phase: Int64 = 0,
        field: UInt32? = nil,
        amount: Double = 0,
        integerField: UInt32? = nil,
        integerValue: Int64 = 0
    ) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = CGEventType(rawValue: 29)!
        event.setIntegerValueField(rawField(110), value: hidType)
        event.setIntegerValueField(rawField(132), value: phase)
        if let field {
            event.setDoubleValueField(rawField(field), value: amount)
        }
        if let integerField {
            event.setIntegerValueField(rawField(integerField), value: integerValue)
        }
        return event
    }

    private func rawField(_ value: UInt32) -> CGEventField {
        CGEventField(rawValue: value)!
    }
}
