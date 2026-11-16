import Foundation
import Network
import Testing
@testable import ThunderLink

struct ClipboardHandshakeTests {
    @Test func authenticatedCapabilityCreatesScopedSessionAndTransfersBothWays() throws {
        let transport = ClipboardHandshakeTransport()
        let hello = DispatchSemaphore(value: 0)
        let sessionReady = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let sessionEnded = DispatchSemaphore(value: 0)
        let acknowledged = DispatchSemaphore(value: 0)
        let acknowledgementSent = DispatchSemaphore(value: 0)
        let box = ClipboardCallbackBox()
        transport.onSent = { message in
            if message.type == .hello { hello.signal() }
            if message.type == .clipboardAck {
                box.sentAcknowledgement = message.clipboardRevision
                acknowledgementSent.signal()
            }
        }
        transport.onClipboardSent = { payload in
            box.sentPayload = payload
            sent.signal()
        }

        let client = ControllerClient(connectionTimeout: 2)
        client.onClipboardSession = { session in
            if let session {
                box.session = session
                sessionReady.signal()
            } else {
                sessionEnded.signal()
            }
        }
        client.onClipboardReceived = { session, payload in
            box.receivedSession = session
            box.receivedPayload = payload
            received.signal()
        }
        client.onClipboardAcknowledged = { session, revision in
            box.acknowledgedSession = session
            box.acknowledgedRevision = revision
            acknowledged.signal()
        }
        client.connect(transport: transport, name: "peer", code: "123456", edge: .right)
        #expect(hello.wait(timeout: .now() + 2) == .success)
        transport.onMessage?(WireMessage(
            type: .helloAck,
            protocolVersion: 2,
            capabilities: [ClipboardPayload.capability]
        ))
        #expect(sessionReady.wait(timeout: .now() + 2) == .success)
        let session = try #require(box.session)
        let payload = makePayload(counter: 1, text: "ThunderLink")

        client.sendClipboard(payload, session: UUID())
        #expect(sent.wait(timeout: .now() + 0.1) == .timedOut)
        client.sendClipboard(payload, session: session)
        #expect(sent.wait(timeout: .now() + 2) == .success)
        #expect(box.sentPayload == payload)

        var chunks = ClipboardSendState(payload: payload)
        while let message = chunks.nextMessage() { transport.onMessage?(message) }
        #expect(received.wait(timeout: .now() + 2) == .success)
        #expect(box.receivedSession == session)
        #expect(box.receivedPayload == payload)
        transport.onMessage?(WireMessage(
            type: .clipboardAck,
            clipboardRevision: payload.revision
        ))
        #expect(acknowledged.wait(timeout: .now() + 2) == .success)
        #expect(box.acknowledgedSession == session)
        #expect(box.acknowledgedRevision == payload.revision)

        client.acknowledgeClipboard(payload.revision, session: UUID())
        client.acknowledgeClipboard(payload.revision, session: session)
        #expect(acknowledgementSent.wait(timeout: .now() + 2) == .success)
        #expect(acknowledgementSent.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(box.sentAcknowledgement == payload.revision)

        client.disconnect()
        #expect(sessionEnded.wait(timeout: .now() + 2) == .success)
    }

    @Test func legacyPeerNeverStartsOrReceivesAClipboardSession() {
        let transport = ClipboardHandshakeTransport()
        let hello = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        let sessionChanged = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        transport.onSent = { if $0.type == .hello { hello.signal() } }
        transport.onClipboardSent = { _ in sent.signal() }

        let client = ControllerClient(connectionTimeout: 2)
        client.onReady = { ready.signal() }
        client.onClipboardSession = { _ in sessionChanged.signal() }
        client.onClipboardReceived = { _, _ in received.signal() }
        client.connect(transport: transport, name: "legacy", code: "123456", edge: .right)
        #expect(hello.wait(timeout: .now() + 2) == .success)
        transport.onMessage?(WireMessage(type: .helloAck, protocolVersion: 1))
        #expect(ready.wait(timeout: .now() + 2) == .success)

        let payload = makePayload(counter: 1, text: "private")
        client.sendClipboard(payload, session: UUID())
        var chunks = ClipboardSendState(payload: payload)
        while let message = chunks.nextMessage() { transport.onMessage?(message) }
        #expect(sent.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(received.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(sessionChanged.wait(timeout: .now() + 0.1) == .timedOut)
        client.disconnect()
    }

    @Test func reconnectReplacesTheClipboardSessionToken() throws {
        let client = ControllerClient(connectionTimeout: 2)
        let sessions = ClipboardSessionBox()
        let sessionReady = DispatchSemaphore(value: 0)
        client.onClipboardSession = { session in
            if let session {
                sessions.values.append(session)
                sessionReady.signal()
            }
        }

        for number in 1...2 {
            let transport = ClipboardHandshakeTransport()
            let hello = DispatchSemaphore(value: 0)
            transport.onSent = { if $0.type == .hello { hello.signal() } }
            client.connect(
                transport: transport,
                name: "peer-\(number)",
                code: "123456",
                edge: .right
            )
            #expect(hello.wait(timeout: .now() + 2) == .success)
            transport.onMessage?(WireMessage(
                type: .helloAck,
                protocolVersion: 2,
                capabilities: [ClipboardPayload.capability]
            ))
            #expect(sessionReady.wait(timeout: .now() + 2) == .success)
        }

        #expect(sessions.values.count == 2)
        #expect(sessions.values[0] != sessions.values[1])
        client.disconnect()
    }

    private func makePayload(counter: UInt64, text: String) -> ClipboardPayload {
        ClipboardPayload(
            revision: ClipboardRevision(counter: counter, origin: UUID()),
            format: .text,
            data: Data(text.utf8)
        )
    }
}

private final class ClipboardHandshakeTransport: ConnectionTransport {
    var onMessage: ((WireMessage) -> Void)?
    var onState: ((NWConnection.State) -> Void)?
    var onInvalidFrame: ((Error) -> Void)?
    var onTransportError: ((Error) -> Void)?
    var onSent: ((WireMessage) -> Void)?
    var onClipboardSent: ((ClipboardPayload) -> Void)?

    func start() { onState?(.ready) }
    func send(_ message: WireMessage) { onSent?(message) }
    func sendClipboard(_ payload: ClipboardPayload) { onClipboardSent?(payload) }
    func sendThenClose(
        _ message: WireMessage,
        deadline: TimeInterval,
        completion: @escaping () -> Void
    ) {
        onSent?(message)
        completion()
    }
    func cancel() {}
    func usesThunderboltBridge() -> Bool { true }
}

private final class ClipboardCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSession: UUID?
    private var storedReceivedSession: UUID?
    private var storedSentPayload: ClipboardPayload?
    private var storedReceivedPayload: ClipboardPayload?
    private var storedAcknowledgedSession: UUID?
    private var storedAcknowledgedRevision: ClipboardRevision?
    private var storedSentAcknowledgement: ClipboardRevision?

    var session: UUID? {
        get { lock.withLock { storedSession } }
        set { lock.withLock { storedSession = newValue } }
    }
    var receivedSession: UUID? {
        get { lock.withLock { storedReceivedSession } }
        set { lock.withLock { storedReceivedSession = newValue } }
    }
    var sentPayload: ClipboardPayload? {
        get { lock.withLock { storedSentPayload } }
        set { lock.withLock { storedSentPayload = newValue } }
    }
    var receivedPayload: ClipboardPayload? {
        get { lock.withLock { storedReceivedPayload } }
        set { lock.withLock { storedReceivedPayload = newValue } }
    }
    var acknowledgedSession: UUID? {
        get { lock.withLock { storedAcknowledgedSession } }
        set { lock.withLock { storedAcknowledgedSession = newValue } }
    }
    var acknowledgedRevision: ClipboardRevision? {
        get { lock.withLock { storedAcknowledgedRevision } }
        set { lock.withLock { storedAcknowledgedRevision = newValue } }
    }
    var sentAcknowledgement: ClipboardRevision? {
        get { lock.withLock { storedSentAcknowledgement } }
        set { lock.withLock { storedSentAcknowledgement = newValue } }
    }
}

private final class ClipboardSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [UUID] = []

    var values: [UUID] {
        get { lock.withLock { storedValues } }
        set { lock.withLock { storedValues = newValue } }
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
