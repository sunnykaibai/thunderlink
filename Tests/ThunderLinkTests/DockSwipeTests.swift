import CoreGraphics
import Testing
@testable import ThunderLink

struct DockSwipeTests {
    @Test func remoteHorizontalSwipeProducesOneArrowAndConsumesRepeatedEnd() {
        var swipe = DockSwipe()
        #expect(swipe.handle(event(axis: 1, phase: 1), remote: true).consume)
        #expect(swipe.handle(event(axis: 1, phase: 2, progress: 0.8), remote: true).consume)

        let ended = swipe.handle(event(axis: 1, phase: 4, progress: 0.8, velocity: 0.2), remote: true)
        #expect(ended.consume)
        #expect(ended.arrow == 124)

        let repeatedEnd = swipe.handle(event(axis: 1, phase: 4, progress: 0.8, velocity: 0.2), remote: true)
        #expect(repeatedEnd.consume)
        #expect(repeatedEnd.arrow == nil)
    }

    @Test func horizontalAndVerticalSignsMapToSystemArrowKeys() {
        #expect(completedArrow(axis: 1, progress: -0.9, velocity: -0.2) == 123)
        #expect(completedArrow(axis: 1, progress: 0.9, velocity: 0.2) == 124)
        #expect(completedArrow(axis: 2, progress: 0.9, velocity: 0.2) == 126)
        #expect(completedArrow(axis: 2, progress: -0.9, velocity: -0.2) == 125)
    }

    @Test func encodedFloatProgressIsUsedWhenDirectFieldIsAbsent() {
        var swipe = DockSwipe()
        _ = swipe.handle(event(axis: 1, phase: 1), remote: true)
        let changed = event(axis: 1, phase: 2, encodedProgress: 0.75)
        #expect(swipe.handle(changed, remote: true).consume)
        let ended = swipe.handle(event(axis: 1, phase: 4), remote: true)
        #expect(ended.arrow == 124)
    }

    @Test func peekCancelAndReversalDoNotCommit() {
        #expect(completedArrow(axis: 1, progress: 0.3, velocity: 0.01) == nil)
        #expect(completedArrow(axis: 1, progress: 0.8, velocity: -0.2) == nil)

        var cancelled = DockSwipe()
        _ = cancelled.handle(event(axis: 2, phase: 1), remote: true)
        _ = cancelled.handle(event(axis: 2, phase: 2, progress: 0.9), remote: true)
        let result = cancelled.handle(event(axis: 2, phase: 8, progress: 0.9), remote: true)
        #expect(result.consume)
        #expect(result.arrow == nil)
    }

    @Test func gestureThatStartedLocallyNeverTransfersMidStream() {
        var swipe = DockSwipe()
        #expect(!swipe.handle(event(axis: 1, phase: 1), remote: false).consume)
        #expect(!swipe.handle(event(axis: 1, phase: 2, progress: 0.8), remote: true).consume)
        let ended = swipe.handle(event(axis: 1, phase: 4, progress: 0.8, velocity: 0.2), remote: true)
        #expect(!ended.consume)
        #expect(ended.arrow == nil)
    }

    @Test func returningLocalDrainsRemoteGestureWithoutCommitting() {
        var swipe = DockSwipe()
        _ = swipe.handle(event(axis: 1, phase: 1), remote: true)
        _ = swipe.handle(event(axis: 1, phase: 2, progress: 0.8), remote: true)
        swipe.release()

        #expect(swipe.handle(event(axis: 1, phase: 2, progress: 1.0), remote: false).consume)
        let ended = swipe.handle(event(axis: 1, phase: 4, progress: 1.0, velocity: 0.2), remote: false)
        #expect(ended.consume)
        #expect(ended.arrow == nil)
    }

    @Test func unrelatedMalformedAndUnsupportedDockEventsPassThrough() {
        var swipe = DockSwipe()
        let ordinary = CGEvent(source: nil)!
        ordinary.type = .mouseMoved
        #expect(!swipe.handle(ordinary, remote: true).consume)
        #expect(!swipe.handle(event(hidType: 7, axis: 1, phase: 1), remote: true).consume)
        #expect(!swipe.handle(event(axis: 3, phase: 1), remote: true).consume)
        #expect(!swipe.handle(event(axis: 1, phase: 16), remote: true).consume)
        #expect(!swipe.handle(event(axis: 1, phase: 2), remote: true).consume)
    }

    private func completedArrow(axis: Int64, progress: Double, velocity: Double) -> CGKeyCode? {
        var swipe = DockSwipe()
        _ = swipe.handle(event(axis: axis, phase: 1), remote: true)
        _ = swipe.handle(event(axis: axis, phase: 2, progress: progress), remote: true)
        return swipe.handle(
            event(axis: axis, phase: 4, progress: progress, velocity: velocity),
            remote: true
        ).arrow
    }

    private func event(
        hidType: Int64 = 23,
        axis: Int64,
        phase: Int64,
        progress: Double = 0,
        velocity: Double = 0,
        encodedProgress: Float? = nil
    ) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = CGEventType(rawValue: 30)!
        event.setIntegerValueField(field(110), value: hidType)
        event.setIntegerValueField(field(123), value: axis)
        event.setDoubleValueField(field(124), value: progress)
        event.setDoubleValueField(field(129), value: velocity)
        event.setDoubleValueField(field(130), value: velocity)
        event.setIntegerValueField(field(132), value: phase)
        if let encodedProgress {
            event.setIntegerValueField(
                field(135),
                value: Int64(UInt64(encodedProgress.bitPattern))
            )
        }
        return event
    }

    private func field(_ rawValue: UInt32) -> CGEventField {
        CGEventField(rawValue: rawValue)!
    }
}
