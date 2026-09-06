import Foundation
import Network
import Testing
@testable import ThunderLink

struct ReceiverServiceTests {
    @Test func rejectedPairingSendsErrorBeforeClosing() throws {
        let listenerReady = DispatchSemaphore(value: 0)
        let clientReady = DispatchSemaphore(value: 0)
        let errorReceived = DispatchSemaphore(value: 0)
        let remoteClosed = DispatchSemaphore(value: 0)
        let portBox = PortBox()
        let receiver = ReceiverService(
            port: .any,
            authenticationTimeout: 1,
            bridgeValidator: { _ in true }
        )
        receiver.onListening = { port in
            portBox.port = port
            listenerReady.signal()
        }
        try receiver.start(pairingCode: "123456")
        defer { receiver.stop() }

        #expect(listenerReady.wait(timeout: .now() + 3) == .success)
        let port = try #require(portBox.port)
        let queue = DispatchQueue(label: "com.sunny.thunderlink.tests.receiver-reject")
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        var buffer = Data()

        func receiveNext() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, complete, error in
                if let data { buffer.append(data) }
                if let messages = try? WireCodec.decodeLines(from: &buffer),
                   messages.contains(where: { $0.type == .error }) {
                    errorReceived.signal()
                }
                if complete || error != nil {
                    remoteClosed.signal()
                } else {
                    receiveNext()
                }
            }
        }

        client.stateUpdateHandler = { state in
            if case .ready = state {
                clientReady.signal()
                if let payload = try? WireCodec.encode(
                    .hello(name: "client", code: "wrong!", edge: .right)
                ) {
                    client.send(content: payload, completion: .idempotent)
                }
            }
        }
        receiveNext()
        client.start(queue: queue)
        defer { client.cancel() }

        #expect(clientReady.wait(timeout: .now() + 3) == .success)
        #expect(errorReceived.wait(timeout: .now() + 3) == .success)
        #expect(remoteClosed.wait(timeout: .now() + 3) == .success)
    }

    @Test func unauthenticatedConnectionIsClosedAtDeadline() throws {
        let listenerReady = DispatchSemaphore(value: 0)
        let remoteClosed = DispatchSemaphore(value: 0)
        let portBox = PortBox()
        let receiver = ReceiverService(
            port: .any,
            authenticationTimeout: 0.2,
            bridgeValidator: { _ in true }
        )
        receiver.onListening = { port in
            portBox.port = port
            listenerReady.signal()
        }
        try receiver.start(pairingCode: "123456")
        defer { receiver.stop() }

        #expect(listenerReady.wait(timeout: .now() + 3) == .success)
        let port = try #require(portBox.port)
        let queue = DispatchQueue(label: "com.sunny.thunderlink.tests.receiver-timeout")
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { _, _, complete, error in
            if complete || error != nil { remoteClosed.signal() }
        }
        client.start(queue: queue)
        defer { client.cancel() }

        #expect(remoteClosed.wait(timeout: .now() + 3) == .success)
    }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPort: NWEndpoint.Port?

    var port: NWEndpoint.Port? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPort
        }
        set {
            lock.lock()
            storedPort = newValue
            lock.unlock()
        }
    }
}
