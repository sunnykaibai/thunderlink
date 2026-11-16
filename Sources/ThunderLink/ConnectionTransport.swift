import Foundation
import Network

/// Shared transport contract so connection lifecycle tests can exercise a stalled
/// resolver without relying on external DNS or a second Mac.
protocol ConnectionTransport: AnyObject {
    var onMessage: ((WireMessage) -> Void)? { get set }
    var onState: ((NWConnection.State) -> Void)? { get set }
    var onInvalidFrame: ((Error) -> Void)? { get set }
    var onTransportError: ((Error) -> Void)? { get set }
    func start()
    func send(_ message: WireMessage)
    func sendClipboard(_ payload: ClipboardPayload)
    func sendThenClose(_ message: WireMessage, deadline: TimeInterval, completion: @escaping () -> Void)
    func cancel()
    func usesThunderboltBridge() -> Bool
}

extension ConnectionTransport {
    /// Test transports and older adapters do not need to implement clipboard
    /// transfer until they advertise clipboard-v1.
    func sendClipboard(_ payload: ClipboardPayload) {}
}
