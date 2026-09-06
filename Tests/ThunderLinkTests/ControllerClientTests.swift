import Foundation
import Network
import Testing
@testable import ThunderLink

struct ControllerClientTests {
    @Test func acceptsLegacyVersionTwoHelloAck() {
        let transport = MockConnectionTransport()
        let helloSent = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        transport.onSent = { message in
            if message.type == .hello { helloSent.signal() }
        }

        let client = ControllerClient(connectionTimeout: 2)
        client.onReady = { ready.signal() }
        client.connect(transport: transport, name: "legacy", code: "123456", edge: .right)

        #expect(helloSent.wait(timeout: .now() + 2) == .success)
        transport.onMessage?(WireMessage(type: .helloAck, protocolVersion: 2))
        #expect(ready.wait(timeout: .now() + 2) == .success)
        client.disconnect()
    }

    @Test func releaseRequiresAuthenticationAndIsDeliveredOncePerConnection() {
        let transport = MockConnectionTransport()
        let helloSent = DispatchSemaphore(value: 0)
        let activateSent = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        transport.onSent = { message in
            if message.type == .hello { helloSent.signal() }
            if message.type == .activate { activateSent.signal() }
        }

        let client = ControllerClient(connectionTimeout: 2)
        client.onRelease = { released.signal() }
        client.connect(transport: transport, name: "peer", code: "123456", edge: .right)

        #expect(helloSent.wait(timeout: .now() + 2) == .success)
        transport.onMessage?(WireMessage(type: .release))
        #expect(released.wait(timeout: .now() + 0.1) == .timedOut)

        transport.onMessage?(WireMessage(type: .helloAck, protocolVersion: 1))
        client.send(WireMessage(type: .activate))
        #expect(activateSent.wait(timeout: .now() + 2) == .success)
        transport.onMessage?(WireMessage(type: .release))
        transport.onMessage?(WireMessage(type: .release))
        #expect(released.wait(timeout: .now() + 2) == .success)
        #expect(released.wait(timeout: .now() + 0.1) == .timedOut)

        client.send(WireMessage(type: .activate))
        #expect(activateSent.wait(timeout: .now() + 2) == .success)
        transport.onMessage?(WireMessage(type: .release))
        #expect(released.wait(timeout: .now() + 2) == .success)
        client.disconnect()
    }
}

private final class MockConnectionTransport: ConnectionTransport {
    var onMessage: ((WireMessage) -> Void)?
    var onState: ((NWConnection.State) -> Void)?
    var onInvalidFrame: ((Error) -> Void)?
    var onTransportError: ((Error) -> Void)?
    var onSent: ((WireMessage) -> Void)?

    func start() { onState?(.ready) }
    func send(_ message: WireMessage) { onSent?(message) }
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
