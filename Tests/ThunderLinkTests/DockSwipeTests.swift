import Carbon.HIToolbox
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

    @Test func horizontalSignsMapToSystemArrowKeys() {
        #expect(completedArrow(axis: 1, progress: -0.9, velocity: -0.2) == 123)
        #expect(completedArrow(axis: 1, progress: 0.9, velocity: 0.2) == 124)
    }

    @Test func legacyUpwardSwipeOpensMissionControlAndDownwardSwipeShowsApplicationWindows() {
        for velocity in [0.0, 0.2] {
            #expect(completedArrow(axis: 2, progress: -0.9, velocity: -velocity) == CGKeyCode(kVK_UpArrow))
            #expect(completedArrow(axis: 2, progress: 0.9, velocity: velocity) == CGKeyCode(kVK_DownArrow))
        }
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

    @Test func nativeFramesKeepTheirOwnerAcrossTheEntireSwipe() throws {
        var swipe = DockSwipe()
        let began = event(axis: 2, phase: 1)
        let changed = event(axis: 2, phase: 2, progress: 0.42)
        let ended = event(axis: 2, phase: 4, progress: 0.9)
        let first = swipe.handle(began, remote: true, native: true)
        #expect(first.consume && first.frame?.phase == .began)
        #expect(swipe.handle(changed, remote: true, native: true).frame?.offset == Double(Float(0.42)))
        #expect(swipe.cancelNativeGesture()?.phase == .cancelled)
        swipe.release()
        let trailing = swipe.handle(ended, remote: false, native: true)
        #expect(trailing.consume && trailing.arrow == nil && trailing.frame == nil)

        #expect(!swipe.handle(began, remote: false, native: true).consume)
        #expect(!swipe.handle(ended, remote: true, native: true).consume)
    }

    @Test func queuePreservesNativeGestureTransitionsAndMostRecentAbsoluteOffset() throws {
        var queue = OutboundMessageQueue(capacity: 8)
        for (phase, offset) in [(1, 0.0), (2, 0.1), (2, 0.6), (4, 1.0)] {
            let frame = try #require(DesktopGestureFrame(capturing: event(axis: 1, phase: Int64(phase), progress: offset)))
            queue.enqueue(WireMessage(type: .desktopGesture, desktopGesture: frame))
        }
        #expect(queue.messages.compactMap { $0.desktopGesture?.phase } == [.began, .changed, .ended])
        #expect(queue.messages[1].desktopGesture?.offset == Double(Float(0.6)))
    }

    @Test func legacyShortcutPostsArrowFlagsAndRefreshesPointerInPlace() {
        for arrow: CGKeyCode in [123, 124, 125, 126] {
            var events: [CGEvent] = []
            let receiver = InputInjector(eventPoster: { events.append($0) }, primaryBounds: {
                CGRect(x: 0, y: 0, width: 100, height: 100)
            })
            receiver.activate(edge: .right)
            let entry = events[0].location
            events.removeAll()
            let controller = InputController()
            var controlTransitions: [String] = []
            controller.onSend = { message in
                if message.keyCode == 59, let kind = message.eventKind {
                    controlTransitions.append(kind)
                }
                receiver.handle(message)
            }
            controller.sendDesktopShortcut(arrow)
            // Older receivers track keys for disconnect cleanup only for down/up.
            #expect(controlTransitions == ["down", "up"])
            #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged, .mouseMoved])
            #expect(events[1].getIntegerValueField(.keyboardEventKeycode) == Int64(arrow))
            #expect(events[1].flags.contains([.maskControl, .maskNumericPad, .maskSecondaryFn]))
            #expect(events[2].flags == events[1].flags)
            #expect(!events[0].flags.contains(.maskNumericPad))
            #expect(!events[3].flags.contains(.maskControl))
            #expect(events[4].location == entry)
        }
    }

    @Test func handoffToleratesSmallReversalsAndStillReturnsAtEitherEdge() {
        for edge: TransferEdge in [.right, .left] {
            let receiver = InputInjector(eventPoster: { _ in }, primaryBounds: {
                CGRect(x: 0, y: 0, width: 300, height: 160)
            })
            var releases = 0
            receiver.onReleaseRequested = { releases += 1 }
            InputController.activationMessages(edge: edge).forEach(receiver.handle)
            let sign = edge == .right ? -1.0 : 1.0
            receiver.handle(WireMessage(type: .mouseMove, deltaX: 4 * sign, deltaY: 0))
            #expect(releases == 0)
            receiver.handle(WireMessage(type: .mouseMove, deltaX: 30 * sign, deltaY: 0))
            #expect(releases == 1)
        }
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
