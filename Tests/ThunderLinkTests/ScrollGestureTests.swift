import CoreGraphics
import Foundation
import Testing
@testable import ThunderLink

struct ScrollGestureTests {
    @Test func scrollMessageKeepsLegacyDeltasAndGesturePhases() throws {
        let event = makeScroll(vertical: 7, horizontal: -3)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(CGScrollPhase.changed.rawValue)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(CGMomentumScrollPhase.begin.rawValue)
        )
        let message = ScrollGesture.message(from: event)
        var buffer = try WireCodec.encode(message)
        let decoded = try #require(WireCodec.decodeLines(from: &buffer).first)

        #expect(decoded.scrollX == -3)
        #expect(decoded.scrollY == 7)
        #expect(decoded.scrollPreciseX?.isFinite == true)
        #expect(decoded.scrollPreciseY?.isFinite == true)
        #expect(decoded.scrollPhase == UInt64(CGScrollPhase.changed.rawValue))
        #expect(decoded.scrollMomentumPhase == UInt64(CGMomentumScrollPhase.begin.rawValue))
        #expect(decoded.scrollContinuous == true)
    }

    @Test func oldScrollMessageStillPostsTheSamePixelDistance() {
        let recorder = ScrollRecorder()
        let injector = makeInjector(recorder)
        injector.activate(edge: .right)
        injector.handle(WireMessage(type: .scroll, scrollX: -3, scrollY: 7))

        let event = recorder.scrollEvents.first
        #expect(event?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 7)
        #expect(event?.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -3)
    }

    @Test func phaseBoundariesAreNeitherCoalescedNorDroppedAsDisposable() {
        var queue = OutboundMessageQueue(capacity: 8)
        let began = WireMessage(
            type: .scroll,
            scrollPreciseX: 0,
            scrollPreciseY: 0,
            scrollPhase: UInt64(CGScrollPhase.began.rawValue)
        )
        let changed = WireMessage(
            type: .scroll,
            scrollPreciseX: 0,
            scrollPreciseY: 1,
            scrollPhase: UInt64(CGScrollPhase.changed.rawValue)
        )
        let ended = WireMessage(
            type: .scroll,
            scrollPreciseX: 0,
            scrollPreciseY: 0,
            scrollPhase: UInt64(CGScrollPhase.ended.rawValue)
        )
        queue.enqueue(began)
        queue.enqueue(changed)
        queue.enqueue(changed)
        queue.enqueue(ended)

        #expect(queue.messages.count == 3)
        #expect(queue.messages[1].scrollPreciseY == 2)
        #expect(queue.messages.map(\.scrollPhase) == [
            UInt64(CGScrollPhase.began.rawValue),
            UInt64(CGScrollPhase.changed.rawValue),
            UInt64(CGScrollPhase.ended.rawValue)
        ])

        var fullQueue = OutboundMessageQueue(capacity: 8)
        for keyCode in 0..<8 {
            fullQueue.enqueue(WireMessage(type: .key, keyCode: UInt16(keyCode)))
        }
        #expect(fullQueue.enqueue(ended) == .criticalOverflow)
    }

    @Test func preciseFractionsAccumulateAndMalformedValuesAreRejected() {
        let recorder = ScrollRecorder()
        let injector = makeInjector(recorder)
        injector.activate(edge: .right)
        for _ in 0..<4 {
            injector.handle(WireMessage(
                type: .scroll,
                scrollX: 0,
                scrollY: 0,
                scrollPreciseX: 0,
                scrollPreciseY: 0.25,
                scrollPhase: UInt64(CGScrollPhase.changed.rawValue),
                scrollContinuous: true
            ))
        }
        injector.handle(WireMessage(
            type: .scroll,
            scrollPreciseX: .infinity,
            scrollPreciseY: 1
        ))

        #expect(recorder.scrollEvents.count == 4)
        #expect(recorder.scrollEvents.reduce(Int64(0)) {
            $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        } == 1)
    }

    @Test func ordinaryWheelDoesNotSwitchToPreciseScaling() {
        let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 2,
            wheel1: 2,
            wheel2: -1,
            wheel3: 0
        )!
        let message = ScrollGesture.message(from: event)

        #expect(message.scrollPreciseX == nil)
        #expect(message.scrollPreciseY == nil)
        #expect(message.scrollContinuous == nil)
    }

    private func makeScroll(vertical: Int32, horizontal: Int32) -> CGEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        )!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return event
    }

    private func makeInjector(_ recorder: ScrollRecorder) -> InputInjector {
        InputInjector(
            eventPoster: { event in
                if event.type == .scrollWheel { recorder.scrollEvents.append(event) }
            },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
    }

    private final class ScrollRecorder {
        var scrollEvents: [CGEvent] = []
    }
}
