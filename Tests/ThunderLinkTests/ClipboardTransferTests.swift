import Foundation
import Network
import Testing
@testable import ThunderLink

struct ClipboardTransferTests {
    @Test func textAndPngPayloadsRoundTripAcrossBoundedWireFrames() throws {
        for (format, size) in [(ClipboardFormat.text, 0), (.png, ClipboardChunk.dataBytes * 2 + 73)] {
            let revision = ClipboardRevision(counter: UInt64(size + 1), origin: UUID())
            let payload = ClipboardPayload(
                revision: revision,
                format: format,
                data: Data((0..<size).map { UInt8($0 % 251) })
            )
            var sender = ClipboardSendState(payload: payload)
            var assembler = ClipboardAssembler()
            var completed: ClipboardPayload?
            var frameCount = 0
            while let message = sender.nextMessage() {
                #expect(try WireCodec.encode(message).count <= WireCodec.maxFrameBytes + 1)
                completed = assembler.receive(message) ?? completed
                frameCount += 1
            }
            #expect(frameCount == max(1, (size + ClipboardChunk.dataBytes - 1) / ClipboardChunk.dataBytes))
            #expect(completed == payload)
        }
    }

    @Test func revisionsHaveADeterministicTotalOrder() {
        let lowOrigin = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highOrigin = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(ClipboardRevision(counter: 1, origin: highOrigin) < ClipboardRevision(counter: 2, origin: lowOrigin))
        #expect(ClipboardRevision(counter: 2, origin: lowOrigin) < ClipboardRevision(counter: 2, origin: highOrigin))
    }

    @Test func assemblerRejectsOversizeOutOfOrderAndInconsistentTransfers() {
        let revision = ClipboardRevision(counter: 1, origin: UUID())
        var assembler = ClipboardAssembler()
        let outOfOrder = ClipboardChunk(
            revision: revision,
            format: .png,
            index: 1,
            count: 2,
            totalBytes: ClipboardChunk.dataBytes + 1,
            data: Data([7])
        )
        #expect(assembler.receive(WireMessage(type: .clipboardChunk, clipboardChunk: outOfOrder)) == nil)

        let oversize = ClipboardChunk(
            revision: revision,
            format: .png,
            index: 0,
            count: 1,
            totalBytes: ClipboardPayload.maxBytes + 1,
            data: Data()
        )
        #expect(assembler.receive(WireMessage(type: .clipboardChunk, clipboardChunk: oversize)) == nil)

        let first = ClipboardChunk(
            revision: revision,
            format: .png,
            index: 0,
            count: 2,
            totalBytes: ClipboardChunk.dataBytes + 1,
            data: Data(repeating: 1, count: ClipboardChunk.dataBytes)
        )
        #expect(assembler.receive(WireMessage(type: .clipboardChunk, clipboardChunk: first)) == nil)
        let mismatched = ClipboardChunk(
            revision: revision,
            format: .text,
            index: 1,
            count: 2,
            totalBytes: ClipboardChunk.dataBytes + 1,
            data: Data([2])
        )
        #expect(assembler.receive(WireMessage(type: .clipboardChunk, clipboardChunk: mismatched)) == nil)
    }

    @Test func duplicateChunksAndCompletedTransfersAreIdempotent() throws {
        let payload = ClipboardPayload(
            revision: ClipboardRevision(counter: 7, origin: UUID()),
            format: .png,
            data: Data(repeating: 0xA5, count: ClipboardChunk.dataBytes * 2 + 1)
        )
        var sender = ClipboardSendState(payload: payload)
        let firstOptional = sender.nextMessage()
        let first = try #require(firstOptional)
        let middleOptional = sender.nextMessage()
        let middle = try #require(middleOptional)
        let lastOptional = sender.nextMessage()
        let last = try #require(lastOptional)
        var assembler = ClipboardAssembler()
        #expect(assembler.receive(first) == nil)
        #expect(assembler.receive(middle) == nil)
        #expect(assembler.receive(first) == nil)
        #expect(assembler.receive(last) == payload)
        #expect(assembler.receive(last) == nil)
        #expect(assembler.receive(first) == nil)
    }

    @Test func aNewFirstChunkReplacesAnIncompleteTransfer() throws {
        let old = ClipboardPayload(
            revision: ClipboardRevision(counter: 1, origin: UUID()),
            format: .png,
            data: Data(repeating: 1, count: ClipboardChunk.dataBytes + 1)
        )
        let new = ClipboardPayload(
            revision: ClipboardRevision(counter: 2, origin: UUID()),
            format: .text,
            data: Data("replacement".utf8)
        )
        var oldSender = ClipboardSendState(payload: old)
        var newSender = ClipboardSendState(payload: new)
        var assembler = ClipboardAssembler()
        let oldFirst = oldSender.nextMessage()
        #expect(assembler.receive(try #require(oldFirst)) == nil)
        let newFirst = newSender.nextMessage()
        #expect(assembler.receive(try #require(newFirst)) == new)
        let oldLast = oldSender.nextMessage()
        #expect(assembler.receive(try #require(oldLast)) == nil)
    }

    @Test func slashHeavyBase64AndAcknowledgementsStayWithinTheFrameBudget() throws {
        let revision = ClipboardRevision(counter: 9, origin: UUID())
        let chunk = ClipboardChunk(
            revision: revision,
            format: .png,
            index: 0,
            count: 1,
            totalBytes: ClipboardChunk.dataBytes,
            data: Data(repeating: 0xFF, count: ClipboardChunk.dataBytes)
        )
        let encoded = try WireCodec.encode(WireMessage(type: .clipboardChunk, clipboardChunk: chunk))
        #expect(encoded.count <= WireCodec.maxFrameBytes + 1)

        let acknowledgement = WireMessage(type: .clipboardAck, clipboardRevision: revision)
        var buffer = try WireCodec.encode(acknowledgement)
        #expect(try WireCodec.decodeLines(from: &buffer) == [acknowledgement])
    }

    @Test func maximumSizePayloadAssemblesWithoutLosingBytes() throws {
        let payload = ClipboardPayload(
            revision: ClipboardRevision(counter: 10, origin: UUID()),
            format: .png,
            data: Data(repeating: 0x5A, count: ClipboardPayload.maxBytes)
        )
        var sender = ClipboardSendState(payload: payload)
        var assembler = ClipboardAssembler()
        var received: ClipboardPayload?
        while let message = sender.nextMessage() {
            received = assembler.receive(message) ?? received
        }
        let result = try #require(received)
        #expect(result.revision == payload.revision)
        #expect(result.format == .png)
        #expect(result.data.count == ClipboardPayload.maxBytes)
        #expect(result.data.first == 0x5A)
        #expect(result.data.last == 0x5A)
    }

    @Test func helloAdvertisesClipboardCapability() {
        let hello = WireMessage.hello(name: "Mac", code: "123456", edge: .right)
        #expect(hello.capabilities?.contains(ClipboardPayload.capability) == true)
    }

    @Test func framedConnectionReplacesPendingClipboardAndInterleavesOrdinaryMessages() throws {
        let listenerQueue = DispatchQueue(label: "com.sunny.thunderlink.tests.clipboard-listener")
        let clientQueue = DispatchQueue(label: "com.sunny.thunderlink.tests.clipboard-client")
        let listenerReady = DispatchSemaphore(value: 0)
        let clientReady = DispatchSemaphore(value: 0)
        let receivedEnough = DispatchSemaphore(value: 0)
        let recorder = ClipboardFrameRecorder(targetCount: 4, completion: receivedEnough)

        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            recorder.connection = connection
            connection.start(queue: listenerQueue)
            recorder.receiveNext(on: listenerQueue)
        }
        listener.start(queue: listenerQueue)
        defer {
            recorder.connection?.cancel()
            listener.cancel()
        }

        #expect(listenerReady.wait(timeout: .now() + 3) == .success)
        let port = try #require(listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let framed = FramedConnection(connection: connection, queue: clientQueue)
        framed.onState = { state in
            if case .ready = state { clientReady.signal() }
        }
        framed.start()
        defer { framed.cancel() }
        #expect(clientReady.wait(timeout: .now() + 3) == .success)

        clientQueue.suspend()
        let old = ClipboardPayload(
            revision: ClipboardRevision(counter: 1, origin: UUID()),
            format: .png,
            data: Data(repeating: 1, count: ClipboardChunk.dataBytes * 3)
        )
        let newest = ClipboardPayload(
            revision: ClipboardRevision(counter: 2, origin: UUID()),
            format: .png,
            data: Data(repeating: 2, count: ClipboardChunk.dataBytes * 2 + 1)
        )
        framed.sendClipboard(old)
        framed.sendClipboard(newest)
        framed.send(WireMessage(type: .ping))
        clientQueue.resume()

        #expect(receivedEnough.wait(timeout: .now() + 5) == .success)
        let messages = recorder.messages
        #expect(messages.map(\.type) == [.clipboardChunk, .ping, .clipboardChunk, .clipboardChunk])
        #expect(messages.compactMap(\.clipboardChunk).allSatisfy { $0.revision == newest.revision })
    }
}

private final class ClipboardFrameRecorder: @unchecked Sendable {
    var connection: NWConnection?
    private(set) var messages: [WireMessage] = []
    private var buffer = Data()
    private let targetCount: Int
    private let completion: DispatchSemaphore

    init(targetCount: Int, completion: DispatchSemaphore) {
        self.targetCount = targetCount
        self.completion = completion
    }

    func receiveNext(on queue: DispatchQueue) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let decoded = try? WireCodec.decodeLines(from: &self.buffer) {
                self.messages.append(contentsOf: decoded)
            }
            if self.messages.count >= self.targetCount {
                self.completion.signal()
            } else if !complete, error == nil {
                self.receiveNext(on: queue)
            }
        }
    }
}
