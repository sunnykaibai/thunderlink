import Foundation
import Network

final class ControllerClient {
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onAppGestureCapabilityChanged: ((Bool) -> Void)?
    var onDesktopGestureCapabilityChanged: ((Bool) -> Void)?
    var onClipboardSession: ((UUID?) -> Void)?
    var onClipboardReceived: ((UUID, ClipboardPayload) -> Void)?
    var onClipboardAcknowledged: ((UUID, ClipboardRevision) -> Void)?
    var onRelease: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onAuthenticationRejected: (() -> Void)?

    private let queue = DispatchQueue(label: "com.sunny.thunderlink.controller")
    private let pendingMessages = BoundedMessageMailbox()
    private var framed: (any ConnectionTransport)?
    private var authenticated = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPong = Date.distantPast
    private var connectionTimer: DispatchSourceTimer?
    private var awaitingHelloAck = false
    private var remoteReleaseReceived = false
    private var remoteSupportsAppGestures = false
    private var remoteSupportsDesktopGestures = false
    private var remoteSupportsClipboard = false
    private var clipboardSession: UUID?
    private var clipboardAssembler = ClipboardAssembler()
    private let connectionTimeout: TimeInterval

    init(connectionTimeout: TimeInterval = 12) {
        self.connectionTimeout = connectionTimeout
    }

    deinit {
        connectionTimer?.cancel()
        heartbeatTimer?.cancel()
        framed?.cancel()
    }

    func connect(to peer: DiscoveredPeer, code: String, edge: TransferEdge) {
        let parameters = ThunderLinkNetwork.tcpParameters()
        parameters.includePeerToPeer = false
        parameters.requiredInterface = peer.interface
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        let framed = FramedConnection(connection: connection, queue: queue)
        connect(transport: framed, name: peer.name, code: code, edge: edge)
    }

    func connect(transport: any ConnectionTransport, name: String, code: String, edge: TransferEdge) {
        queue.async { [weak self] in
            self?.startConnection(transport, name: name, code: code, edge: edge)
        }
    }

    private func startConnection(_ framed: any ConnectionTransport, name: String, code: String, edge: TransferEdge) {
        resetConnection(notify: false)
        self.framed = framed
        framed.onState = { [weak self, weak framed] state in
            guard let self, let framed, self.framed === framed else { return }
            switch state {
            case .ready:
                guard framed.usesThunderboltBridge() else {
                    self.finish(framed, status: "连接没有经过 bridge0，已拒绝")
                    return
                }
                self.awaitingHelloAck = true
                ThunderLinkLog.network.info("controller transport ready on bridge0")
                self.onStatus?("已通过 bridge0 连接，正在验证配对码")
                framed.send(.hello(
                    name: Host.current().localizedName ?? "Mac",
                    code: code,
                    edge: edge
                ))
            case .waiting(let error):
                self.onStatus?("等待连接：\(error.localizedDescription)")
            case .failed(let error):
                self.finish(framed, status: "连接失败：\(error.localizedDescription)")
            case .cancelled:
                self.finish(framed, status: "连接已断开")
            default: break
            }
        }
        framed.onMessage = { [weak self, weak framed] message in
            guard let framed else { return }
            self?.handle(message, from: framed)
        }
        framed.onInvalidFrame = { [weak self, weak framed] _ in
            guard let self, let framed else { return }
            self.finish(framed, status: "对端返回了无效数据")
        }
        framed.onTransportError = { [weak self, weak framed] error in
            guard let self, let framed else { return }
            self.finish(framed, status: "雷电连接中断：\(error.localizedDescription)")
        }
        onStatus?("正在连接 \(name)…（最多 \(Int(connectionTimeout)) 秒）")
        startConnectionDeadline(for: framed)
        framed.start()
    }

    func disconnect() {
        queue.async { [weak self] in self?.resetConnection(notify: true) }
    }

    func sendClipboard(_ payload: ClipboardPayload, session: UUID) {
        queue.async { [weak self] in
            guard let self, self.authenticated, self.remoteSupportsClipboard,
                  self.clipboardSession == session, let framed = self.framed else { return }
            framed.sendClipboard(payload)
        }
    }

    func acknowledgeClipboard(_ revision: ClipboardRevision, session: UUID) {
        queue.async { [weak self] in
            guard let self, self.authenticated, self.remoteSupportsClipboard,
                  self.clipboardSession == session else { return }
            self.framed?.send(WireMessage(
                type: .clipboardAck,
                clipboardRevision: revision
            ))
        }
    }

    private func resetConnection(notify: Bool) {
        let previous = framed
        let hadConnection = previous != nil || authenticated
        framed = nil
        authenticated = false
        awaitingHelloAck = false
        remoteReleaseReceived = false
        setRemoteAppGestureSupport(false)
        setRemoteDesktopGestureSupport(false)
        setClipboardSupport(false)
        pendingMessages.reset()
        stopConnectionDeadline()
        stopHeartbeat()
        previous?.cancel()
        if notify && hadConnection { onDisconnected?() }
    }

    func send(_ message: WireMessage) {
        switch pendingMessages.offer(message) {
        case .accepted(let scheduleDrain):
            if scheduleDrain {
                queue.async { [weak self] in self?.drainPendingMessages() }
            }
        case .droppedDisposable, .closed:
            break
        case .criticalOverflow:
            queue.async { [weak self] in
                guard let self, let framed = self.framed else { return }
                self.finish(framed, status: "输入积压超过安全上限，连接已断开")
            }
        }
    }

    private func handle(_ message: WireMessage, from framed: any ConnectionTransport) {
        guard self.framed === framed else { return }
        switch message.type {
        case .helloAck:
            guard awaitingHelloAck, !authenticated,
                  let protocolVersion = message.protocolVersion,
                  protocolVersion == 1 || protocolVersion == 2 else {
                finish(framed, status: "对端配对响应的协议版本无效")
                return
            }
            authenticated = true
            awaitingHelloAck = false
            remoteReleaseReceived = false
            stopConnectionDeadline()
            if message.capabilities?.contains("heartbeat-v1") == true {
                startHeartbeat(for: framed)
            }
            setRemoteAppGestureSupport(
                message.capabilities?.contains("app-gesture-v1") == true
            )
            setRemoteDesktopGestureSupport(
                message.capabilities?.contains("desktop-gesture-v1") == true
            )
            setClipboardSupport(
                message.capabilities?.contains(ClipboardPayload.capability) == true
            )
            ThunderLinkLog.network.info(
                "peer capabilities: heartbeat=\(message.capabilities?.contains("heartbeat-v1") == true, privacy: .public), appGesture=\(self.remoteSupportsAppGestures, privacy: .public), desktopGesture=\(self.remoteSupportsDesktopGestures, privacy: .public), clipboard=\(self.remoteSupportsClipboard, privacy: .public)"
            )
            onStatus?("已配对；把指针移到所选屏幕边缘即可控制对端")
            onReady?()
        case .pong:
            if authenticated { lastPong = Date() }
        case .release:
            guard authenticated, !remoteReleaseReceived else { return }
            remoteReleaseReceived = true
            ThunderLinkLog.input.notice("Receiver requested pointer return")
            onRelease?()
        case .clipboardChunk:
            guard authenticated, remoteSupportsClipboard, let session = clipboardSession,
                  let payload = clipboardAssembler.receive(message) else { return }
            onClipboardReceived?(session, payload)
        case .clipboardAck:
            guard authenticated, remoteSupportsClipboard, let session = clipboardSession,
                  let revision = message.clipboardRevision else { return }
            onClipboardAcknowledged?(session, revision)
        case .error:
            if awaitingHelloAck && !authenticated { onAuthenticationRejected?() }
            finish(framed, status: "对端拒绝连接：\(message.message ?? "未知原因")")
        default: break
        }
    }

    private func finish(_ source: any ConnectionTransport, status: String) {
        guard framed === source else { return }
        let wasConnected = framed != nil || authenticated
        framed = nil
        authenticated = false
        awaitingHelloAck = false
        remoteReleaseReceived = false
        setRemoteAppGestureSupport(false)
        setRemoteDesktopGestureSupport(false)
        setClipboardSupport(false)
        pendingMessages.reset()
        stopConnectionDeadline()
        stopHeartbeat()
        source.cancel()
        ThunderLinkLog.network.error("controller disconnected: \(status, privacy: .public)")
        onStatus?(status)
        if wasConnected { onDisconnected?() }
    }

    private func startConnectionDeadline(for framed: any ConnectionTransport) {
        stopConnectionDeadline()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + connectionTimeout)
        timer.setEventHandler { [weak self, weak framed] in
            guard let self, let framed, self.framed === framed, !self.authenticated else { return }
            let reason = self.awaitingHelloAck
                ? "配对响应超时：请确认对端已开始接收，然后重试"
                : "连接超时：请检查本机的本地网络权限及对端接收状态"
            self.finish(framed, status: reason)
        }
        connectionTimer = timer
        timer.resume()
    }

    private func drainPendingMessages() {
        let messages = pendingMessages.drain()
        guard authenticated, let framed else { return }
        for message in messages {
            if message.type == .appGesture, !remoteSupportsAppGestures { continue }
            if message.type == .desktopGesture, !remoteSupportsDesktopGestures { continue }
            if message.type == .activate { remoteReleaseReceived = false }
            framed.send(message)
        }
    }

    private func setRemoteAppGestureSupport(_ supported: Bool) {
        guard remoteSupportsAppGestures != supported else { return }
        remoteSupportsAppGestures = supported
        onAppGestureCapabilityChanged?(supported)
    }

    private func setRemoteDesktopGestureSupport(_ supported: Bool) {
        guard remoteSupportsDesktopGestures != supported else { return }
        remoteSupportsDesktopGestures = supported
        onDesktopGestureCapabilityChanged?(supported)
    }

    private func setClipboardSupport(_ supported: Bool) {
        remoteSupportsClipboard = supported
        clipboardAssembler = ClipboardAssembler()
        let session = supported ? UUID() : nil
        guard clipboardSession != session else { return }
        clipboardSession = session
        onClipboardSession?(session)
    }

    private func stopConnectionDeadline() {
        connectionTimer?.setEventHandler {}
        connectionTimer?.cancel()
        connectionTimer = nil
    }

    private func startHeartbeat(for framed: any ConnectionTransport) {
        stopHeartbeat()
        lastPong = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self, weak framed] in
            guard let self, let framed, self.framed === framed, self.authenticated else { return }
            if Date().timeIntervalSince(self.lastPong) > 8 {
                self.finish(framed, status: "雷电连接心跳超时，正在重新发现对端")
                return
            }
            framed.send(WireMessage(type: .ping))
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.setEventHandler {}
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}
