import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            Picker("用途", selection: $model.role) {
                ForEach(AppRole.allCases) { role in Text(role.title).tag(role) }
            }
            .pickerStyle(.segmented)

            if model.role == .controller { controllerPanel } else { receiverPanel }

            Divider()
            statusPanel
            automationPanel
            permissionPanel
        }
        .padding(24)
        .frame(width: 580)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 34))
                .foregroundStyle(model.networkState.isActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("ThunderLink").font(.title2.bold())
                Text("只通过雷电桥共享键盘和鼠标")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.networkState.summary)
                .font(.caption.monospaced())
                .foregroundStyle(model.networkState.isActive ? .green : .red)
        }
    }

    private var controllerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("另一台 Mac").font(.headline)
            if model.peers.isEmpty {
                Text(model.controllerConnected ? "已连接，设备发现已暂停。" :
                     (model.controllerConnecting ? "正在连接所选设备…" : "没有在 bridge0 上发现运行中的 ThunderLink 接收端。"))
                    .foregroundStyle(.secondary)
            } else {
                Picker("设备", selection: $model.selectedPeerID) {
                    ForEach(model.peers) { peer in Text(peer.name).tag(Optional(peer.id)) }
                }
            }
            HStack {
                SecureField("被控端的 6 位配对码", text: $model.enteredCode)
                    .textFieldStyle(.roundedBorder)
                Picker("切换边缘", selection: $model.transferEdge) {
                    ForEach(TransferEdge.allCases) { edge in Text(edge.title).tag(edge) }
                }
                .frame(width: 150)
            }
            HStack {
                Button(model.controllerConnected ? "断开" : (model.controllerConnecting ? "取消连接" : "连接")) {
                    if model.controllerConnected || model.controllerConnecting {
                        model.disconnectController()
                    } else {
                        model.connectSelectedPeer()
                    }
                }
                .keyboardShortcut(.defaultAction)
                Text(model.controlling ? "键盘和鼠标当前在另一台 Mac" : "")
                    .foregroundStyle(.orange)
            }
            Text("紧急恢复本机：Control + Option + Escape。请先松开按键和鼠标按钮，再移到屏幕边缘切换。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var receiverPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配对码").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(model.pairingCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button("更换") { model.regeneratePairingCode() }
                Spacer()
            }
            Text("把这 6 位数字输入主控端。接收端只接受来自 bridge0 的连接。")
                .foregroundStyle(.secondary)
            HStack {
                Button(model.receiverRunning ? "停止接收" : (model.receiverStarting ? "取消启动" : "开始接收")) {
                    (model.receiverRunning || model.receiverStarting) ? model.stopReceiver() : model.startReceiver()
                }
                .keyboardShortcut(.defaultAction)
                if let name = model.remoteControllerName { Text("已连接：\(name)") }
            }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("状态").font(.headline)
            Text(model.connectionStatus)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var automationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自动运行").font(.headline)
            Toggle("登录时自动启动 ThunderLink", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Text(model.loginItemStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.automaticBehaviorDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统权限").font(.headline)
            HStack {
                permissionLabel("辅助功能", granted: model.accessibilityGranted)
                Spacer()
                if !model.accessibilityGranted {
                    Button("打开辅助功能设置") { model.requestPermissions() }
                }
            }
            if !model.accessibilityGranted {
                Text("在「隐私与安全性」的「辅助功能」列表中允许 ThunderLink，即可使用跨机键鼠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionLabel(_ title: String, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(granted ? .green : .orange)
    }
}
