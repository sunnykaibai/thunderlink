import Foundation
import Network
import Testing
@testable import ThunderLink

struct FramedConnectionTests {
    @Test func remoteClosureIsReportedAsTransportFailure() throws {
        let queue = DispatchQueue(label: "com.sunny.thunderlink.tests.transport")
        let listenerReady = DispatchSemaphore(value: 0)
        let clientReady = DispatchSemaphore(value: 0)
        let serverAccepted = DispatchSemaphore(value: 0)
        let transportFailed = DispatchSemaphore(value: 0)
        let box = ConnectionBox()

        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            box.connection = connection
            connection.start(queue: queue)
            serverAccepted.signal()
        }
        listener.start(queue: queue)
        defer {
            box.connection?.cancel()
            listener.cancel()
        }

        #expect(listenerReady.wait(timeout: .now() + 3) == .success)
        let port = try #require(listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let framed = FramedConnection(connection: connection, queue: queue)
        framed.onState = { state in
            if case .ready = state { clientReady.signal() }
        }
        framed.onTransportError = { _ in transportFailed.signal() }
        framed.start()
        defer { framed.cancel() }

        #expect(clientReady.wait(timeout: .now() + 3) == .success)
        #expect(serverAccepted.wait(timeout: .now() + 3) == .success)
        box.connection?.cancel()
        #expect(transportFailed.wait(timeout: .now() + 5) == .success)
    }

    @Test func sendThenCloseDeliversFinalFrameBeforeCompletion() throws {
        let queue = DispatchQueue(label: "com.sunny.thunderlink.tests.graceful-close")
        let listenerReady = DispatchSemaphore(value: 0)
        let clientReady = DispatchSemaphore(value: 0)
        let frameReceived = DispatchSemaphore(value: 0)
        let closeCompleted = DispatchSemaphore(value: 0)
        let box = ConnectionBox()

        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            box.connection = connection
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, _ in
                guard var data else { return }
                if (try? WireCodec.decodeLines(from: &data)) == [WireMessage(type: .error, message: "rejected")] {
                    frameReceived.signal()
                }
            }
        }
        listener.start(queue: queue)
        defer {
            box.connection?.cancel()
            listener.cancel()
        }

        #expect(listenerReady.wait(timeout: .now() + 3) == .success)
        let port = try #require(listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let framed = FramedConnection(connection: connection, queue: queue)
        framed.onState = { state in
            if case .ready = state { clientReady.signal() }
        }
        framed.start()
        defer { framed.cancel() }

        #expect(clientReady.wait(timeout: .now() + 3) == .success)
        framed.sendThenClose(WireMessage(type: .error, message: "rejected"), deadline: 2) {
            closeCompleted.signal()
        }
        #expect(frameReceived.wait(timeout: .now() + 3) == .success)
        #expect(closeCompleted.wait(timeout: .now() + 3) == .success)
    }
}

private final class ConnectionBox: @unchecked Sendable {
    var connection: NWConnection?
}
