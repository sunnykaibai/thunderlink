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
    func sendThenClose(_ message: WireMessage, deadline: TimeInterval, completion: @escaping () -> Void)
    func cancel()
    func usesThunderboltBridge() -> Bool
}
