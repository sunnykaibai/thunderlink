import Foundation
import Testing
@testable import ThunderLink

struct InputMessageDeliveryTests {
    @Test func disconnectDuringDrainInvalidatesTheRemainingBatch() {
        let queue = DispatchQueue(label: "test.input.delivery.inflight")
        queue.suspend()
        let released = DispatchSemaphore(value: 0)
        var messages: [WireMessage] = []
        weak var currentDelivery: InputMessageDelivery?
        let delivery = InputMessageDelivery(capacity: 8, queue: queue,
            onMessage: { message in
                messages.append(message)
                if message.type == .activate { currentDelivery?.reset() }
                if message.type == .release { released.signal() }
            }, onOverflow: { })
        currentDelivery = delivery
        delivery.submit(WireMessage(type: .activate))
        delivery.submit(WireMessage(type: .key, keyCode: 1, eventKind: "down"))
        delivery.submit(WireMessage(type: .key, keyCode: 2, eventKind: "down"))
        queue.resume()
        #expect(released.wait(timeout: .now() + 2) == .success)
        queue.sync { }
        #expect(messages.map(\.type) == [.activate, .release])
    }

    @Test func stalledConsumerFailsOnceInsteadOfSchedulingPerEvent() {
        let queue = DispatchQueue(label: "test.input.delivery.stalled")
        queue.suspend()
        var overflowCount = 0
        var deliveredCount = 0
        let delivery = InputMessageDelivery(capacity: 8, queue: queue,
            onMessage: { _ in deliveredCount += 1 },
            onOverflow: { overflowCount += 1 })
        for _ in 0..<20_000 {
            delivery.submit(WireMessage(type: .key, keyCode: 1, eventKind: "down"))
        }
        #expect(overflowCount == 1)
        queue.resume()
        queue.sync { }
        #expect(deliveredCount <= 8)
    }

    @Test func disconnectDropsOldEventsAndReleasesBeforeNewActivation() {
        let queue = DispatchQueue(label: "test.input.delivery.disconnect")
        queue.suspend()
        var messages: [WireMessage] = []
        let delivery = InputMessageDelivery(capacity: 8, queue: queue,
            onMessage: { messages.append($0) }, onOverflow: { })
        delivery.submit(WireMessage(type: .activate))
        delivery.submit(WireMessage(type: .key, keyCode: 1, eventKind: "down"))
        delivery.reset()
        delivery.submit(WireMessage(type: .activate))
        queue.resume()
        queue.sync { }
        #expect(messages.map(\.type) == [.release, .activate])
    }

    @Test func highRateMotionCoalescesWhileMainThreadIsBusy() {
        let queue = DispatchQueue(label: "test.input.delivery.motion")
        queue.suspend()
        var messages: [WireMessage] = []
        let delivery = InputMessageDelivery(capacity: 8, queue: queue,
            onMessage: { messages.append($0) }, onOverflow: { })
        for _ in 0..<20_000 {
            delivery.submit(WireMessage(type: .mouseMove, deltaX: 1, deltaY: 0))
        }
        queue.resume()
        queue.sync { }
        #expect(messages.count == 1)
        #expect(messages.first?.deltaX == 20_000)
    }
}
