import Foundation
import Network

final class FramedConnection: ConnectionTransport {
    let connection: NWConnection
    var onMessage: ((WireMessage) -> Void)?
    var onState: ((NWConnection.State) -> Void)?
    var onInvalidFrame: ((Error) -> Void)?
    var onTransportError: ((Error) -> Void)?
    private var receiveBuffer = Data()
    private let outbound = BoundedMessageMailbox()
    private var isSending = false
    private var clipboardSendState: ClipboardSendState?
    private var lastSentWasClipboard = false
    private var transportErrorReported = false
    private let lifecycleLock = NSLock()
    private var acceptingSends = true
    private var gracefulCloseRequested = false
    private var terminated = false
    private var closeAfterDrain = false
    private var closeCompletion: (() -> Void)?
    private var closeTimer: DispatchSourceTimer?
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState?(state)
            if case .ready = state { self?.receiveNext() }
        }
        connection.start(queue: queue)
    }

    func send(_ message: WireMessage) {
        let result = lifecycleLock.withLock {
            acceptingSends ? outbound.offer(message) : .closed
        }
        handleOfferResult(result)
    }

    func sendClipboard(_ payload: ClipboardPayload) {
        guard payload.data.count <= ClipboardPayload.maxBytes else { return }
        let accepted = lifecycleLock.withLock { () -> Bool in
            guard acceptingSends else { return false }
            if let current = clipboardSendState,
               current.payload.revision >= payload.revision { return false }
            clipboardSendState = ClipboardSendState(payload: payload)
            return true
        }
        if accepted { queue.async { [weak self] in self?.sendNextIfNeeded() } }
    }

    func sendThenClose(
        _ message: WireMessage,
        deadline: TimeInterval = 1,
        completion: @escaping () -> Void
    ) {
        let result: BoundedMessageMailbox.OfferResult? = lifecycleLock.withLock {
            guard acceptingSends else { return nil }
            acceptingSends = false
            gracefulCloseRequested = true
            clipboardSendState = nil
            return outbound.offer(message)
        }
        guard let result else {
            queue.async(execute: completion)
            return
        }

        queue.async { [weak self] in
            guard let self, !self.transportErrorReported else {
                completion()
                return
            }
            self.closeAfterDrain = true
            self.closeCompletion = completion
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + max(0.1, deadline))
            timer.setEventHandler { [weak self] in self?.finishGracefulClose() }
            self.closeTimer = timer
            timer.resume()
            self.handleOfferResult(result)
        }
    }

    func cancel() {
        lifecycleLock.withLock {
            acceptingSends = false
            terminated = true
        }
        connection.cancel()
        queue.async { [weak self] in self?.cleanup() }
    }

    func usesThunderboltBridge() -> Bool {
        guard let path = connection.currentPath else { return false }
        let interfaceIsPresent = path.availableInterfaces.contains { $0.name == "bridge0" }
        guard interfaceIsPresent else { return false }

        // NWPath exposes the concrete local and remote endpoints, but only offers
        // usesInterfaceType(_:) for interface categories. Compare the selected
        // local endpoint with bridge0's live addresses so a Wi-Fi connection to
        // the same Bonjour service cannot pass this check.
        let bridge = NetworkInterfaceDetector.thunderboltBridge()
        let local = path.localEndpoint?.debugDescription ?? ""
        if let ipv4 = bridge.ipv4, local.contains(ipv4) { return true }
        if let ipv6 = bridge.ipv6 {
            let address = ipv6.replacingOccurrences(of: "%bridge0", with: "")
            if local.contains(address) && local.contains("bridge0") { return true }
        }
        return false
    }

    private func receiveNext() {
        guard lifecycleLock.withLock({ !terminated }) else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: WireCodec.maxFrameBytes + 1
        ) { [weak self] data, _, complete, error in
            guard let self, self.lifecycleLock.withLock({ !self.terminated }) else { return }
            if let data { self.receiveBuffer.append(data) }
            do {
                for message in try WireCodec.decodeLines(from: &self.receiveBuffer) {
                    guard self.lifecycleLock.withLock({ !self.terminated }) else { return }
                    self.onMessage?(message)
                }
            } catch {
                self.onInvalidFrame?(error)
                self.cancel()
                return
            }
            guard self.lifecycleLock.withLock({ !self.terminated }) else { return }
            if let error {
                self.reportTransportError(error)
            } else if complete {
                self.reportTransportError(FrameError.remoteClosed)
            } else {
                self.receiveNext()
            }
        }
    }

    private func sendNextIfNeeded() {
        guard !isSending else { return }
        let message: WireMessage?
        if lastSentWasClipboard, let ordinary = outbound.nextOrBecomeIdle() {
            lastSentWasClipboard = false
            message = ordinary
        } else if let clipboard = nextClipboardMessage() {
            lastSentWasClipboard = true
            message = clipboard
        } else {
            lastSentWasClipboard = false
            message = outbound.nextOrBecomeIdle()
        }
        guard let message else {
            if closeAfterDrain { finishGracefulClose() }
            return
        }
        let payload: Data
        do {
            payload = try WireCodec.encode(message)
        } catch {
            onInvalidFrame?(error)
            cancel()
            return
        }
        isSending = true
        let isFinalMessage = lifecycleLock.withLock { gracefulCloseRequested } && outbound.isEmpty
        let context: NWConnection.ContentContext = isFinalMessage ? .finalMessage : .defaultMessage
        connection.send(
            content: payload,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.isSending = false
                    if let error {
                        self.reportTransportError(error)
                    } else {
                        self.sendNextIfNeeded()
                    }
                }
            })
    }

    private func nextClipboardMessage() -> WireMessage? {
        lifecycleLock.withLock {
            guard var state = clipboardSendState else { return nil }
            let message = state.nextMessage()
            clipboardSendState = state.hasRemainingChunks ? state : nil
            return message
        }
    }

    private func reportTransportError(_ error: Error) {
        guard !transportErrorReported else { return }
        transportErrorReported = true
        lifecycleLock.withLock {
            acceptingSends = false
            gracefulCloseRequested = false
            terminated = true
            clipboardSendState = nil
        }
        lastSentWasClipboard = false
        outbound.clear()
        ThunderLinkLog.network.error("transport failed: \(error.localizedDescription, privacy: .public)")
        onTransportError?(error)
        connection.cancel()
        cleanup()
    }

    private func handleOfferResult(_ result: BoundedMessageMailbox.OfferResult) {
        switch result {
        case .accepted(let scheduleDrain):
            if scheduleDrain {
                queue.async { [weak self] in self?.sendNextIfNeeded() }
            }
        case .droppedDisposable, .closed:
            break
        case .criticalOverflow:
            queue.async { [weak self] in
                self?.reportTransportError(FrameError.outboundQueueOverflow)
            }
        }
    }

    private func finishGracefulClose() {
        guard closeAfterDrain || closeCompletion != nil else { return }
        closeAfterDrain = false
        closeTimer?.setEventHandler {}
        closeTimer?.cancel()
        closeTimer = nil
        let completion = closeCompletion
        closeCompletion = nil
        connection.cancel()
        cleanup()
        completion?()
    }

    private func cleanup() {
        lifecycleLock.withLock {
            acceptingSends = false
            gracefulCloseRequested = false
            terminated = true
            clipboardSendState = nil
        }
        closeTimer?.setEventHandler {}
        closeTimer?.cancel()
        closeTimer = nil
        closeAfterDrain = false
        let completion = closeCompletion
        closeCompletion = nil
        outbound.clear()
        lastSentWasClipboard = false
        receiveBuffer.removeAll(keepingCapacity: false)
        connection.stateUpdateHandler = nil
        onMessage = nil
        onState = nil
        onInvalidFrame = nil
        onTransportError = nil
        completion?()
    }

    enum FrameError: LocalizedError {
        case remoteClosed
        case outboundQueueOverflow

        var errorDescription: String? {
            switch self {
            case .remoteClosed: return "对端已关闭连接"
            case .outboundQueueOverflow: return "发送队列已满，关键输入事件无法安全排队"
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

enum ThunderLinkNetwork {
    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        return NWParameters(tls: nil, tcp: tcp)
    }
}
