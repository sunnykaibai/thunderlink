import Foundation
import Network
import Testing
@testable import ThunderLink

struct HandshakeGestureTests {
    @Test func gestureCapabilityIsScopedToOneAuthenticatedConnection() {
        let first = GestureHandshakeTransport()
        let firstHello = DispatchSemaphore(value: 0)
        let firstGesture = DispatchSemaphore(value: 0)
        let capabilityEnabled = DispatchSemaphore(value: 0)
        let capabilityDisabled = DispatchSemaphore(value: 0)
        first.onSent = {
            if $0.type == .hello { firstHello.signal() }
            if $0.type == .appGesture { firstGesture.signal() }
        }

        let client = ControllerClient(connectionTimeout: 2)
        client.onAppGestureCapabilityChanged = { supported in
            (supported ? capabilityEnabled : capabilityDisabled).signal()
        }
        client.connect(transport: first, name: "new", code: "123456", edge: .right)
        #expect(firstHello.wait(timeout: .now() + 2) == .success)
        first.onMessage?(WireMessage(
            type: .helloAck,
            protocolVersion: 2,
            capabilities: ["app-gesture-v1"]
        ))
        #expect(capabilityEnabled.wait(timeout: .now() + 2) == .success)
        client.send(WireMessage(type: .appGesture))
        #expect(firstGesture.wait(timeout: .now() + 2) == .success)
        client.disconnect()
        #expect(capabilityDisabled.wait(timeout: .now() + 2) == .success)

        let second = GestureHandshakeTransport()
        let secondHello = DispatchSemaphore(value: 0)
        let secondGesture = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        second.onSent = {
            if $0.type == .hello { secondHello.signal() }
            if $0.type == .appGesture { secondGesture.signal() }
        }
        client.onReady = { ready.signal() }
        client.connect(transport: second, name: "old", code: "123456", edge: .right)
        #expect(secondHello.wait(timeout: .now() + 2) == .success)
        second.onMessage?(WireMessage(type: .helloAck, protocolVersion: 1))
        #expect(ready.wait(timeout: .now() + 2) == .success)
        #expect(capabilityEnabled.wait(timeout: .now() + 0.1) == .timedOut)
        client.send(WireMessage(type: .appGesture))
        #expect(secondGesture.wait(timeout: .now() + 0.1) == .timedOut)
        client.disconnect()
    }
}

private final class GestureHandshakeTransport: ConnectionTransport {
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
