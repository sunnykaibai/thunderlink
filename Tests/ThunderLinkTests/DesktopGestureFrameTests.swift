import CoreGraphics
import Foundation
import Testing
@testable import ThunderLink

struct DesktopGestureFrameTests {
    @Test func capturesAndRebuildsAnAllowlistedDockSwipeFrame() throws {
        let original = event(axis: 2, phase: 4, offset: 1.25, velocityX: 0, velocityY: 40)
        let frame = try #require(DesktopGestureFrame(capturing: original))
        var posted: [CGEvent] = []
        let playback = DesktopGesturePlayback(eventPoster: { posted.append($0.copy()!) })

        #expect(playback.handle(capture(axis: 2, phase: 1, offset: 0.1), at: CGPoint(x: 7, y: 11)))
        #expect(playback.handle(frame, at: CGPoint(x: 7, y: 11)))
        #expect(posted.map(\.type.rawValue) == [30, 29, 30, 29])
        let rebuilt = posted[2]
        #expect(rebuilt.location == CGPoint(x: 7, y: 11))
        #expect(rebuilt.getIntegerValueField(field(110)) == 23)
        #expect(rebuilt.getIntegerValueField(field(123)) == 2)
        #expect(rebuilt.getIntegerValueField(field(132)) == 4)
        #expect(rebuilt.getIntegerValueField(field(134)) == 4)
        #expect(rebuilt.getDoubleValueField(field(124)) == 1.25)
        #expect(rebuilt.getDoubleValueField(field(130)) == 40)
        #expect(DesktopGestureFrame(capturing: rebuilt) == frame)
    }

    @Test func supportsHorizontalVerticalAndPinchAxes() throws {
        for axis: Int64 in [1, 2, 3] {
            let frame = try #require(DesktopGestureFrame(capturing: event(
                axis: axis,
                phase: 2,
                offset: -0.5,
                inverted: 1
            )))
            #expect(frame.invertedFromDevice)
        }
    }

    @Test func playbackRejectsOrphansMismatchesAndRepeatedEnds() throws {
        var posted: [CGEvent] = []
        let playback = DesktopGesturePlayback(eventPoster: { posted.append($0) })
        #expect(!playback.handle(capture(axis: 1, phase: 2), at: .zero))
        #expect(playback.handle(capture(axis: 1, phase: 1), at: .zero))
        #expect(!playback.handle(capture(axis: 2, phase: 2), at: .zero))
        #expect(playback.handle(capture(axis: 1, phase: 4), at: .zero))
        #expect(!playback.handle(capture(axis: 1, phase: 4), at: .zero))
        #expect(posted.count == 4)
    }

    @Test func aNewBeginCancelsAStaleOpenSequenceBeforeStarting() throws {
        var posted: [CGEvent] = []
        let playback = DesktopGesturePlayback(eventPoster: { posted.append($0.copy()!) })
        #expect(playback.handle(capture(axis: 1, phase: 1, offset: 0.2), at: .zero))
        #expect(playback.handle(capture(axis: 2, phase: 1, offset: 0.1), at: .zero))

        #expect(posted.map(\.type.rawValue) == [30, 29, 30, 29, 30, 29])
        #expect(posted[2].getIntegerValueField(field(123)) == 1)
        #expect(posted[2].getIntegerValueField(field(132)) == 8)
        #expect(posted[4].getIntegerValueField(field(123)) == 2)
        #expect(posted[4].getIntegerValueField(field(132)) == 1)
    }

    @Test func encodedFloatOffsetIsUsedWhenTheDirectFieldIsZero() throws {
        let encoded = event(axis: 1, phase: 2)
        encoded.setIntegerValueField(field(135), value: Int64(Float(0.75).bitPattern))
        let frame = try #require(DesktopGestureFrame(capturing: encoded))
        #expect(frame.offset == 0.75)

        encoded.setIntegerValueField(field(135), value: Int64(Float.infinity.bitPattern))
        #expect(DesktopGestureFrame(capturing: encoded) == nil)
    }

    @Test func cancelClosesAnOpenStreamExactlyOnce() throws {
        var posted: [CGEvent] = []
        let playback = DesktopGesturePlayback(eventPoster: { posted.append($0.copy()!) })
        #expect(playback.handle(capture(axis: 1, phase: 1, offset: 0.2), at: .zero))
        playback.cancel(at: CGPoint(x: 3, y: 4))
        playback.cancel(at: CGPoint(x: 3, y: 4))

        #expect(posted.count == 4)
        #expect(posted[2].getIntegerValueField(field(132)) == 8)
        #expect(posted[2].location == CGPoint(x: 3, y: 4))
    }

    @Test func malformedFieldsAndWireValuesAreRejected() {
        #expect(DesktopGestureFrame(capturing: event(hidType: 7, axis: 1, phase: 1)) == nil)
        #expect(DesktopGestureFrame(capturing: event(axis: 9, phase: 1)) == nil)
        #expect(DesktopGestureFrame(capturing: event(axis: 1, phase: 16)) == nil)
        #expect(DesktopGestureFrame(capturing: event(axis: 1, phase: 1, offset: .infinity)) == nil)
        #expect(DesktopGestureFrame(capturing: event(axis: 1, phase: 1, inverted: 2)) == nil)

        let malformed = Data(#"{"axis":1,"phase":1,"offset":99,"velocityX":0,"velocityY":0,"invertedFromDevice":false}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopGestureFrame.self, from: malformed)
        }
    }

    @Test func codableRoundTripPreservesTheValidatedShape() throws {
        let original = capture(axis: 3, phase: 2, offset: -0.75, inverted: 1)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(DesktopGestureFrame.self, from: data) == original)
    }

    private func capture(
        axis: Int64,
        phase: Int64,
        offset: Double = 0,
        inverted: Int64 = 0
    ) -> DesktopGestureFrame {
        DesktopGestureFrame(capturing: event(
            axis: axis,
            phase: phase,
            offset: offset,
            inverted: inverted
        ))!
    }

    private func event(
        hidType: Int64 = 23,
        axis: Int64,
        phase: Int64,
        offset: Double = 0,
        velocityX: Double = 0,
        velocityY: Double = 0,
        inverted: Int64 = 0
    ) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = CGEventType(rawValue: 30)!
        event.setIntegerValueField(field(110), value: hidType)
        event.setIntegerValueField(field(123), value: axis)
        event.setIntegerValueField(field(132), value: phase)
        event.setDoubleValueField(field(124), value: offset)
        event.setDoubleValueField(field(129), value: velocityX)
        event.setDoubleValueField(field(130), value: velocityY)
        event.setIntegerValueField(field(136), value: inverted)
        return event
    }

    private func field(_ value: UInt32) -> CGEventField {
        CGEventField(rawValue: value)!
    }
}
