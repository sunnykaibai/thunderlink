import Foundation
import Testing
@testable import ThunderLink

struct WireCodecTests {
    @Test func roundTripAndFragmentedBuffer() throws {
        let hello = WireMessage.hello(name: "MacBook Pro", code: "123456", edge: .right)
        let move = WireMessage(type: .mouseMove, deltaX: 8, deltaY: -3)
        let bytes = try WireCodec.encode(hello) + WireCodec.encode(move)
        var buffer = Data(bytes.prefix(bytes.count / 2))
        let first = try WireCodec.decodeLines(from: &buffer)
        buffer.append(bytes.suffix(from: bytes.count / 2))
        let second = try WireCodec.decodeLines(from: &buffer)
        #expect(first + second == [hello, move])
        #expect(buffer.isEmpty)
    }

    @Test func incompleteFrameIsRetained() throws {
        var buffer = Data("{\"type\":\"ping\"}".utf8)
        #expect(try WireCodec.decodeLines(from: &buffer).isEmpty)
        #expect(!buffer.isEmpty)
        buffer.append(0x0A)
        #expect(try WireCodec.decodeLines(from: &buffer) == [WireMessage(type: .ping)])
    }

    @Test func oversizedFramesAreRejectedBeforeTheyCanAccumulate() {
        let oversized = WireMessage(
            type: .error,
            message: String(repeating: "x", count: WireCodec.maxFrameBytes)
        )
        #expect(throws: WireCodecError.self) {
            _ = try WireCodec.encode(oversized)
        }

        var unterminated = Data(repeating: 0x78, count: WireCodec.maxFrameBytes + 1)
        #expect(throws: WireCodecError.self) {
            _ = try WireCodec.decodeLines(from: &unterminated)
        }
    }

    @Test func highFrequencyPointerEventsAreCoalesced() {
        var queue = OutboundMessageQueue(capacity: 32)
        for _ in 0..<100_000 {
            queue.enqueue(WireMessage(type: .mouseMove, deltaX: 1, deltaY: -1))
        }
        #expect(queue.count == 1)
        let result = queue.popFirst()
        #expect(result?.deltaX == 100_000)
        #expect(result?.deltaY == -100_000)
    }

    @Test func criticalTransitionsPreserveOrder() {
        var queue = OutboundMessageQueue(capacity: 8)
        queue.enqueue(WireMessage(type: .mouseMove, deltaX: 2, deltaY: 3))
        queue.enqueue(WireMessage(type: .mouseMove, deltaX: 4, deltaY: 5))
        queue.enqueue(WireMessage(type: .mouseButton, eventKind: "down", button: 0))
        queue.enqueue(WireMessage(type: .mouseMove, deltaX: 7, deltaY: 11))
        queue.enqueue(WireMessage(type: .mouseButton, eventKind: "up", button: 0))

        #expect(queue.messages.map(\.type) == [.mouseMove, .mouseButton, .mouseMove, .mouseButton])
        #expect(queue.messages.first?.deltaX == 6)
    }

    @Test func queueNeverExceedsCapacityWhenOnlyCriticalEventsRemain() {
        var queue = OutboundMessageQueue(capacity: 8)
        for keyCode in 0..<8 {
            #expect(queue.enqueue(WireMessage(type: .key, keyCode: UInt16(keyCode))) == .enqueued)
        }

        let result = queue.enqueue(WireMessage(type: .mouseButton, eventKind: "up", button: 0))
        #expect(result == .criticalOverflow)
        #expect(queue.count == 8)
    }

    @Test func mailboxSchedulesOneDrainForABurst() {
        let mailbox = BoundedMessageMailbox(capacity: 16)
        var scheduled = 0
        for keyCode in 0..<8 {
            if case .accepted(let scheduleDrain) = mailbox.offer(
                WireMessage(type: .key, keyCode: UInt16(keyCode))
            ), scheduleDrain {
                scheduled += 1
            }
        }

        #expect(scheduled == 1)
        #expect(mailbox.drain().count == 8)
        if case .accepted(let scheduleDrain) = mailbox.offer(WireMessage(type: .release)) {
            #expect(scheduleDrain)
        } else {
            Issue.record("mailbox should accept after a completed drain")
        }
    }

    @Test func mailboxOverflowClosesUntilResetWithoutGrowing() {
        let mailbox = BoundedMessageMailbox(capacity: 8)
        for keyCode in 0..<8 {
            _ = mailbox.offer(WireMessage(type: .key, keyCode: UInt16(keyCode)))
        }

        if case .criticalOverflow = mailbox.offer(WireMessage(type: .release)) {
            // Expected: losing a release/key transition would leave remote input stuck.
        } else {
            Issue.record("critical overflow was not reported")
        }
        if case .closed = mailbox.offer(WireMessage(type: .release)) {
            // Expected: one overflow produces one disconnect action.
        } else {
            Issue.record("overflowed mailbox accepted additional input")
        }
        #expect(mailbox.count == 8)

        mailbox.reset()
        #expect(mailbox.count == 0)
        if case .accepted = mailbox.offer(WireMessage(type: .release)) {
            // Reset opens the mailbox for the next connection.
        } else {
            Issue.record("reset did not reopen mailbox")
        }
    }
}
