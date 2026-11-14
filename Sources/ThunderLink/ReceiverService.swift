import Foundation
import Network

final class ReceiverService {
    static let port: NWEndpoint.Port = 47_891

    var onStatus: ((String) -> Void)?
    var onControllerChanged: ((String?) -> Void)?
    var onAuthenticatedMessage: ((WireMessage) -> Void)?
    var onDisconnected: (() -> Void)?
    var onListening: ((NWEndpoint.Port) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.sunny.thunderlink.receiver")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let configuredPort: NWEndpoint.Port
    private let authenticationTimeout: TimeInterval
    private let bridgeValidator: (any ConnectionTransport) -> Bool
    private let transportFactory: (NWConnection, DispatchQueue) -> any ConnectionTransport
    private var listener: NWListener?
    private var client: (any ConnectionTransport)?
    private var handshakeTimer: DispatchSourceTimer?
    private var expectedCode = ""
    private var authenticated = false
    private var rejectingClient = false

    init(
        port: NWEndpoint.Port = ReceiverService.port,
        authenticationTimeout: TimeInterval = 8,
        bridgeValidator: @escaping (any ConnectionTransport) -> Bool = { $0.usesThunderboltBridge() },
        transportFactory: @escaping (NWConnection, DispatchQueue) -> any ConnectionTransport = {
            FramedConnection(connection: $0, queue: $1)
        }
    ) {
        configuredPort = port
        self.authenticationTimeout = authenticationTimeout
        self.bridgeValidator = bridgeValidator
        self.transportFactory = transportFactory
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(pairingCode: String) throws {
        let parameters = ThunderLinkNetwork.tcpParameters()
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters, on: configuredPort)
        newListener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Mac",
            type: "_thunderlink._tcp"
        )
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, self.listener === newListener else { return }
            switch state {
            case .ready:
                let port = newListener.port ?? self.configuredPort
                self.onStatus?("正在 bridge0 上等待连接 · TCP \(port.rawValue)")
                self.onListening?(port)
                self.onRunningChanged?(true)
            case .failed(let error):
                self.onStatus?("监听失败：\(error.localizedDescription)")
                self.stopLocked(notifyRunningChanged: false)
                self.onRunningChanged?(false)
            case .waiting(let error):
                self.onStatus?("等待雷电网络：\(error.localizedDescription)")
            case .cancelled:
                self.onStatus?("接收端已停止")
                self.stopLocked(notifyRunningChanged: false)
                self.onRunningChanged?(false)
            default: break
            }
        }
        newListener.newConnectionHandler = { [weak self, weak newListener] connection in
            guard let self, let newListener, self.listener === newListener else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }

        syncOnQueue {
            stopLocked(notifyRunningChanged: false)
            expectedCode = pairingCode
            listener = newListener
            newListener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(notifyRunningChanged: true)
        }
    }

    /// Ends only the active controller connection and keeps the listener alive.
    func disconnectClient(status: String) {
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            self.finishClient(client, status: status)
        }
    }

    func send(_ message: WireMessage) {
        queue.async { [weak self] in
            guard let self, self.authenticated else { return }
            self.client?.send(message)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard client == nil else {
            connection.cancel()
            return
        }
        let framed = transportFactory(connection, queue)
        client = framed
        authenticated = false
        rejectingClient = false
        startHandshakeTimer(for: framed)
        framed.onState = { [weak self, weak framed] state in
            guard let self, let framed, self.client === framed else { return }
            switch state {
            case .ready:
                guard self.bridgeValidator(framed) else {
                    self.rejectClient(
                        framed,
                        message: "只接受通过 Thunderbolt Bridge 的连接",
                        status: "连接未通过 bridge0，已拒绝"
                    )
                    return
                }
                ThunderLinkLog.network.info("receiver accepted transport on bridge0")
                self.onStatus?("收到 bridge0 连接，正在验证配对码")
            case .failed(let error):
                self.finishClient(framed, status: "连接中断：\(error.localizedDescription)")
            case .cancelled:
                self.finishClient(framed, status: "主控端已断开")
            default: break
            }
        }
        framed.onMessage = { [weak self, weak framed] message in
            guard let self, let framed, self.client === framed else { return }
            self.handle(message, from: framed)
        }
        framed.onInvalidFrame = { [weak self, weak framed] _ in
            guard let self, let framed, self.client === framed else { return }
            self.finishClient(framed, status: "收到无效数据，连接已关闭")
        }
        framed.onTransportError = { [weak self, weak framed] error in
            guard let self, let framed, self.client === framed else { return }
            self.finishClient(framed, status: "雷电连接中断：\(error.localizedDescription)")
        }
        framed.start()
    }

    private func handle(_ message: WireMessage, from framed: any ConnectionTransport) {
        guard client === framed, !rejectingClient else { return }
        if !authenticated {
            guard message.type == .hello,
                  message.protocolVersion == 1,
                  message.pairingCode == expectedCode,
                  let name = message.computerName,
                  let edge = message.edge else {
                rejectClient(
                    framed,
                    message: "配对码错误或协议不兼容",
                    status: "配对码错误或协议不兼容"
                )
                return
            }
            authenticated = true
            cancelHandshakeTimer()
            onControllerChanged?(name)
            let desktopGesturesSupported = DesktopGestureFrame.isSupportedOnThisOS
            var capabilities = ["heartbeat-v1", "app-gesture-v1"]
            if desktopGesturesSupported { capabilities.append("desktop-gesture-v1") }
            framed.send(WireMessage(
                type: .helloAck,
                protocolVersion: 2,
                edge: edge,
                capabilities: capabilities
            ))
            ThunderLinkLog.network.info(
                "controller capabilities: heartbeat=\(message.capabilities?.contains("heartbeat-v1") == true, privacy: .public), receiver desktopGesture=\(desktopGesturesSupported, privacy: .public)"
            )
            onStatus?("已与 \(name) 通过 bridge0 配对")
            return
        }
        if message.type == .ping {
            framed.send(WireMessage(type: .pong))
            return
        }
        if message.type == .desktopGesture,
           (!DesktopGestureFrame.isSupportedOnThisOS || message.desktopGesture == nil) {
            ThunderLinkLog.network.error("ignored unsupported or malformed desktop gesture frame")
            return
        }
        onAuthenticatedMessage?(message)
    }

    private func startHandshakeTimer(for source: any ConnectionTransport) {
        cancelHandshakeTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + authenticationTimeout)
        timer.setEventHandler { [weak self, weak source] in
            guard let self, let source,
                  self.client === source,
                  !self.authenticated else { return }
            self.finishClient(source, status: "配对验证超时，连接已关闭")
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func cancelHandshakeTimer() {
        handshakeTimer?.setEventHandler {}
        handshakeTimer?.cancel()
        handshakeTimer = nil
    }

    private func finishClient(_ source: any ConnectionTransport, status: String) {
        guard client === source else { return }
        cancelHandshakeTimer()
        client = nil
        authenticated = false
        rejectingClient = false
        source.cancel()
        ThunderLinkLog.network.error("receiver disconnected: \(status, privacy: .public)")
        onControllerChanged?(nil)
        onDisconnected?()
        onStatus?(status)
    }

    private func rejectClient(_ source: any ConnectionTransport, message: String, status: String) {
        guard client === source, !rejectingClient else { return }
        rejectingClient = true
        cancelHandshakeTimer()
        source.sendThenClose(
            WireMessage(type: .error, message: message),
            deadline: 1
        ) { [weak self, weak source] in
            guard let self, let source else { return }
            self.finishClient(source, status: status)
        }
    }

    private func stopLocked(notifyRunningChanged: Bool) {
        cancelHandshakeTimer()
        let previous = client
        client = nil
        authenticated = false
        rejectingClient = false
        previous?.cancel()
        listener?.cancel()
        listener = nil
        if notifyRunningChanged { onRunningChanged?(false) }
        onControllerChanged?(nil)
        onDisconnected?()
    }

    private func syncOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }
}
