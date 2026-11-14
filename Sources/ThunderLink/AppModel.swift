import AppKit
import Combine
import Foundation
import ServiceManagement

enum AppRole: String, CaseIterable, Identifiable {
    case controller
    case receiver

    var id: String { rawValue }
    var title: String { self == .controller ? "控制另一台 Mac" : "允许这台 Mac 被控制" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var role: AppRole {
        didSet {
            UserDefaults.standard.set(role.rawValue, forKey: DefaultsKey.role)
            roleChanged()
        }
    }
    @Published var transferEdge: TransferEdge {
        didSet {
            inputController.transferEdge = transferEdge
            UserDefaults.standard.set(transferEdge.rawValue, forKey: DefaultsKey.transferEdge)
        }
    }
    @Published var pairingCode: String
    @Published var enteredCode: String {
        didSet { UserDefaults.standard.set(enteredCode, forKey: DefaultsKey.controllerPairingCode) }
    }
    @Published var peers: [DiscoveredPeer] = []
    @Published var selectedPeerID: String?
    @Published var networkState = ThunderboltInterfaceState()
    @Published var connectionStatus = "尚未连接"
    @Published var receiverRunning = false
    @Published private(set) var receiverStarting = false
    @Published var controllerConnected = false
    @Published var controllerConnecting = false
    @Published var controlling = false
    @Published var remoteControllerName: String?
    @Published var accessibilityGranted = false
    @Published var launchAtLogin = false
    @Published var loginItemStatus = "未设置开机启动"
    @Published private(set) var receiverAutoStartEnabled = false
    @Published private(set) var controllerAutoConnectEnabled = false

    var automaticBehaviorDescription: String {
        if role == .receiver {
            return receiverAutoStartEnabled
                ? "获得辅助功能权限后自动监听；断线后继续等待主控端。"
                : "自动接收已关闭。"
        }
        return controllerAutoConnectEnabled
            ? "启动后自动发现并连接上一次选择的 Mac；临时断线后自动恢复。"
            : "首次连接成功后会自动记住对端和配对信息。"
    }

    private let browser = PeerBrowser()
    private let receiver = ReceiverService()
    private let controller = ControllerClient()
    private let inputController = InputController()
    private let injector = InputInjector()
    private var inputDelivery: InputMessageDelivery!
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var wantsControllerConnection = false
    private var targetPeerName: String?
    private var nextReconnectAt = Date.distantPast
    private var nextReceiverRetryAt = Date.distantPast
    private var lastLoggedAccessibilityState: Bool?
    private var initialized = false

    init() {
        let defaults = UserDefaults.standard
        role = AppRole(rawValue: defaults.string(forKey: DefaultsKey.role) ?? "") ?? .controller
        transferEdge = TransferEdge(rawValue: defaults.string(forKey: DefaultsKey.transferEdge) ?? "") ?? .right
        enteredCode = defaults.string(forKey: DefaultsKey.controllerPairingCode) ?? ""
        let stored = defaults.string(forKey: DefaultsKey.pairingCode)
        let code = stored ?? String(Int.random(in: 100_000...999_999))
        pairingCode = code
        if stored == nil { defaults.set(code, forKey: DefaultsKey.pairingCode) }
        receiverAutoStartEnabled = defaults.bool(forKey: DefaultsKey.receiverAutoStart)
        controllerAutoConnectEnabled = defaults.bool(forKey: DefaultsKey.controllerAutoConnect)
        wantsControllerConnection = controllerAutoConnectEnabled
        targetPeerName = defaults.string(forKey: DefaultsKey.targetPeerName)
        bindServices()
        refreshSystemState()
        refreshLoginItemStatus()
        initialized = true
        resumeSavedRole()
        if CommandLine.arguments.contains("--request-accessibility") {
            DispatchQueue.main.async { [weak self] in
                self?.requestPermissions()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSystemState()
                self?.refreshLoginItemStatus()
                self?.resumeSavedRole()
                self?.tryAutomaticReconnect()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // NotificationCenter delivers this observer synchronously on the main
            // queue. Cleanup must finish before termination, not in a later Task.
            MainActor.assumeIsolated {
                self?.inputController.stopMonitoring(force: true)
                self?.injector.releaseAll()
                self?.controller.disconnect()
                self?.receiver.stop()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func startReceiver() {
        setReceiverAutoStart(true)
        nextReceiverRetryAt = .distantPast
        startReceiverIfPossible(requestPermission: true)
    }

    private func startReceiverIfPossible(requestPermission: Bool) {
        guard role == .receiver, !receiverRunning, !receiverStarting,
              Date() >= nextReceiverRetryAt else { return }
        guard networkState.isActive else {
            connectionStatus = "自动接收已开启，正在等待 Thunderbolt Bridge"
            return
        }
        if requestPermission { SystemPermissions.requestAccessibility() }
        refreshSystemState()
        guard accessibilityGranted else {
            connectionStatus = "自动接收已开启；授予辅助功能权限后会自动开始"
            return
        }
        do {
            receiverStarting = true
            try receiver.start(pairingCode: pairingCode)
        } catch {
            receiverStarting = false
            nextReceiverRetryAt = Date().addingTimeInterval(5)
            connectionStatus = "无法启动接收端：\(error.localizedDescription)"
        }
    }

    func stopReceiver() {
        setReceiverAutoStart(false)
        receiver.stop()
        injector.releaseAll()
        receiverRunning = false
        receiverStarting = false
        connectionStatus = "接收端已停止"
    }

    func connectSelectedPeer() {
        guard let peer = peers.first(where: { $0.id == selectedPeerID }) else {
            connectionStatus = "请先选择另一台 Mac"
            return
        }
        let digits = enteredCode.filter(\.isNumber)
        guard digits.count == 6 else {
            connectionStatus = "请输入被控端显示的 6 位配对码"
            return
        }
        SystemPermissions.requestAccessibility()
        refreshSystemState()
        guard accessibilityGranted else {
            connectionStatus = "控制端需要辅助功能权限"
            return
        }
        wantsControllerConnection = true
        controllerAutoConnectEnabled = true
        targetPeerName = peer.name
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKey.controllerAutoConnect)
        defaults.set(peer.name, forKey: DefaultsKey.targetPeerName)
        startControllerConnection(to: peer, code: digits)
    }

    func disconnectController() {
        wantsControllerConnection = false
        controllerAutoConnectEnabled = false
        UserDefaults.standard.set(false, forKey: DefaultsKey.controllerAutoConnect)
        controllerConnecting = false
        inputController.stopMonitoring()
        controller.disconnect()
        controllerConnected = false
        controlling = false
        connectionStatus = "连接已断开"
        if role == .controller { browser.start() }
    }

    func requestPermissions() {
        SystemPermissions.requestAccessibility()
        refreshSystemState()
        if !accessibilityGranted {
            SystemPermissions.openAccessibilitySettings()
        } else {
            resumeSavedRole()
            tryAutomaticReconnect()
        }
    }

    func regeneratePairingCode() {
        let code = String(Int.random(in: 100_000...999_999))
        pairingCode = code
        UserDefaults.standard.set(code, forKey: DefaultsKey.pairingCode)
        if receiverRunning || receiverStarting {
            stopReceiver()
            startReceiver()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                } else if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            loginItemStatus = "开机启动设置失败：\(error.localizedDescription)"
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        refreshLoginItemStatus()
    }

    private func roleChanged() {
        guard initialized else { return }
        if role == .controller {
            receiver.stop()
            injector.releaseAll()
            receiverRunning = false
            receiverStarting = false
            if !controllerConnected && !controllerConnecting { browser.start() }
            wantsControllerConnection = controllerAutoConnectEnabled
            tryAutomaticReconnect()
        } else {
            disconnectController()
            browser.stop()
            peers = []
            setReceiverAutoStart(true)
            startReceiverIfPossible(requestPermission: true)
        }
    }

    private func refreshSystemState() {
        networkState = NetworkInterfaceDetector.thunderboltBridge()
        let currentAccessibilityState = SystemPermissions.accessibilityGranted
        accessibilityGranted = currentAccessibilityState
        if lastLoggedAccessibilityState != currentAccessibilityState {
            ThunderLinkLog.input.notice("Accessibility permission changed: granted=\(currentAccessibilityState, privacy: .public)")
            lastLoggedAccessibilityState = currentAccessibilityState
        }
        if role == .controller, (controllerConnected || controllerConnecting),
           (!accessibilityGranted || !networkState.isActive) {
            inputController.stopMonitoring()
            controller.disconnect()
        }
        if role == .receiver, (receiverRunning || receiverStarting),
           (!accessibilityGranted || !networkState.isActive) {
            receiver.stop()
            injector.releaseAll()
            receiverRunning = false
            receiverStarting = false
        }
    }

    private func resumeSavedRole() {
        guard initialized else { return }
        if role == .receiver {
            if receiverAutoStartEnabled { startReceiverIfPossible(requestPermission: false) }
        } else {
            if !controllerConnected && !controllerConnecting { browser.start() }
            if controllerAutoConnectEnabled {
                wantsControllerConnection = true
            }
        }
    }

    private func setReceiverAutoStart(_ enabled: Bool) {
        receiverAutoStartEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.receiverAutoStart)
    }

    private func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            loginItemStatus = "登录后自动启动"
        case .requiresApproval:
            launchAtLogin = false
            loginItemStatus = "需要在系统设置的登录项中允许"
        case .notRegistered:
            launchAtLogin = false
            loginItemStatus = "未设置开机启动"
        case .notFound:
            launchAtLogin = false
            loginItemStatus = "系统未找到登录项"
        @unknown default:
            launchAtLogin = false
            loginItemStatus = "登录项状态未知"
        }
    }

    private func bindServices() {
        let receiver = self.receiver
        inputDelivery = InputMessageDelivery(onMessage: { [weak self] message in
            guard let self else { return }
            if message.type == .release {
                self.injector.releaseAll()
            } else if self.role == .receiver, self.receiverAutoStartEnabled {
                self.injector.handle(message)
            }
        }, onOverflow: { [weak receiver] in
            receiver?.disconnectClient(status: "输入处理积压已达到上限，已断开并释放输入")
        })
        let inputDelivery = self.inputDelivery!
        browser.onPeersChanged = { [weak self] peers in
            DispatchQueue.main.async {
                self?.peers = peers
                if let selected = self?.selectedPeerID,
                   peers.contains(where: { $0.id == selected }) {
                    // Preserve the current selection while it is still present.
                } else {
                    self?.selectedPeerID = peers.first?.id
                }
                self?.tryAutomaticReconnect()
            }
        }
        browser.onStateChanged = { [weak self] status in
            DispatchQueue.main.async {
                guard self?.controllerConnected == false,
                      self?.controllerConnecting == false,
                      self?.wantsControllerConnection == false else { return }
                self?.connectionStatus = status
            }
        }
        receiver.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard self?.role == .receiver else { return }
                self?.connectionStatus = status
            }
        }
        receiver.onRunningChanged = { [weak self] running in
            DispatchQueue.main.async {
                guard let self, self.role == .receiver else { return }
                self.receiverRunning = running && self.receiverAutoStartEnabled
                self.receiverStarting = false
                if !running { self.nextReceiverRetryAt = Date().addingTimeInterval(5) }
            }
        }
        receiver.onControllerChanged = { [weak self] name in
            DispatchQueue.main.async { self?.remoteControllerName = name }
        }
        receiver.onAuthenticatedMessage = { message in inputDelivery.submit(message) }
        receiver.onDisconnected = { inputDelivery.reset() }
        injector.onReleaseRequested = { [weak self] in
            self?.receiver.send(WireMessage(type: .release))
        }

        controller.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard self?.role == .controller else { return }
                self?.connectionStatus = status
            }
        }
        controller.onReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.role == .controller,
                      self.wantsControllerConnection, self.controllerConnecting else { return }
                do {
                    self.inputController.transferEdge = self.transferEdge
                    try self.inputController.startMonitoring()
                    self.controllerConnected = true
                    self.controllerConnecting = false
                    self.browser.stop()
                } catch {
                    self.connectionStatus = error.localizedDescription
                    self.controller.disconnect()
                }
            }
        }
        controller.onRelease = { [weak self] in
            DispatchQueue.main.async { self?.inputController.releaseFromRemote() }
        }
        controller.onAuthenticationRejected = { [weak self] in
            DispatchQueue.main.async {
                self?.wantsControllerConnection = false
                self?.controllerAutoConnectEnabled = false
                UserDefaults.standard.set(false, forKey: DefaultsKey.controllerAutoConnect)
            }
        }
        controller.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.inputController.stopMonitoring()
                self?.controllerConnected = false
                self?.controllerConnecting = false
                self?.controlling = false
                guard let self, self.role == .controller, self.wantsControllerConnection else { return }
                // Leave the actual failure visible while waiting to retry.
                self.nextReconnectAt = Date().addingTimeInterval(10)
                self.browser.start()
            }
        }
        inputController.onSend = { [weak self] message in self?.controller.send(message) }
        inputController.onError = { [weak self] error in
            DispatchQueue.main.async { self?.connectionStatus = error }
        }
        inputController.onActiveChanged = { [weak self] active in
            DispatchQueue.main.async { self?.controlling = active }
        }
    }

    private func startControllerConnection(to peer: DiscoveredPeer, code: String) {
        guard !controllerConnected, !controllerConnecting else { return }
        controllerConnecting = true
        browser.stop()
        controller.connect(to: peer, code: code, edge: transferEdge)
    }

    private func tryAutomaticReconnect() {
        guard role == .controller,
              wantsControllerConnection,
              !controllerConnected,
              !controllerConnecting,
              accessibilityGranted,
              Date() >= nextReconnectAt,
              let targetPeerName,
              let peer = peers.first(where: { $0.name == targetPeerName }) else { return }
        let digits = enteredCode.filter(\.isNumber)
        guard digits.count == 6 else { return }
        nextReconnectAt = Date().addingTimeInterval(3)
        connectionStatus = "已重新发现 \(targetPeerName)，正在恢复雷电连接"
        startControllerConnection(to: peer, code: digits)
    }

    private enum DefaultsKey {
        static let role = "appRole"
        static let transferEdge = "transferEdge"
        static let pairingCode = "pairingCode"
        static let controllerPairingCode = "controllerPairingCode"
        static let receiverAutoStart = "receiverAutoStart"
        static let controllerAutoConnect = "controllerAutoConnect"
        static let targetPeerName = "targetPeerName"
    }
}
