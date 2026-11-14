# ThunderLink

ThunderLink 0.3.10 是一个只通过 macOS `Thunderbolt Bridge` 共享键盘和鼠标的 App。同一个 App 安装在两台 Mac 上，一台选择“控制另一台 Mac”，另一台选择“允许这台 Mac 被控制”。

Keyboard and mouse sharing between two Macs over Thunderbolt Bridge.

[下载 v0.3.3（Apple Silicon）](https://github.com/sunnykaibai/thunderlink/releases/tag/v0.3.3) · [MIT 许可证](LICENSE) · [验证记录](docs/VALIDATION.md)

## 已实现

- Bonjour 自动发现，但只显示通过 `bridge0` 发现的对端。
- 连接时强制使用发现结果中的 `bridge0` 接口；接收端再次检查实际连接路径。
- 6 位配对码。
- 松开键盘和鼠标按钮后，指针从主控端桌面的左边或右边移出，切换到被控端。本机相邻显示器的共享边缘不会触发切换。
- 键盘按下/松开、修饰键、鼠标移动、点击、双击、远端拖动和滚轮转发。按住鼠标拖动时不会跨到另一台 Mac。
- 两台 Mac 都运行 0.3.8 或更新版本，且系统版本在 macOS 13 至 26 之间时，主控把三指或四指滑动的方向、进度、速度和松手状态发送到对端，由对端系统处理调度中心与桌面切换。系统识别出的桌面捏合手势也使用这条路径。该功能依赖 macOS 未公开的 Dock 手势字段。
- 连接旧版接收端时，上滑在松手时发送 Control + ↑ 打开调度中心，下滑发送 Control + ↓ 显示当前应用的窗口。左右滑动发送 Control 加左右方向键。对端须启用对应的系统快捷键。左右切换还需要有相邻桌面或全屏应用。
- 如果接收端支持应用手势（0.3.7 起），缩放与旋转由鼠标所在的目标应用处理。双指滚动可以传递滚动阶段和惯性；更早的接收端使用普通滚动。
- `Control + Option + Escape` 可在远端控制期间立即恢复本机。
- 断线时清理被控端记录的普通键、修饰键和鼠标按钮；本机对尚未松开的远端输入继续抑制重复和松开事件，直到物理释放。
- TCP keepalive 和应用层心跳检测失效连接，检测到断线后恢复主控端输入。心跳每 2 秒检查一次，距离最后响应超过 8 秒时断开，不能保证拔线瞬间被发现。
- 连接期间停止 Bonjour 浏览，断线后恢复发现并自动重连上一次选择的对端。
- 合并连续的鼠标与滚轮事件。每级事件队列最多保留 256 条消息，只预约一次待执行的处理任务；无法容纳关键事件时断开连接并清理输入。单条协议消息最多 16 KiB。
- 配对错误会先返回错误原因再关闭连接；握手超时和监听失败可以恢复，不再把尚未就绪的监听器显示为正在接收。
- 显示器配置变化后重新取得有效显示器，避免休眠或显示器重连后继续使用失效的显示器编号。
- 控制远端期间在 HID 层截获输入，并固定本机光标；应用位于前台时还会隐藏光标并解除物理鼠标与光标的关联。
- 保存两台 Mac 的角色、配对码、目标设备和屏幕方向；首次设置后自动恢复。
- 被控端获得权限后自动监听，主控端启动后自动重连上一次的对端。
- 可通过 macOS `SMAppService` 注册为登录项，开机登录后自动启动。

## 系统要求与权限

- macOS 13 或更高版本。
- 两台 Mac 通过雷电线连接，并且系统网络设置中存在活动的 `Thunderbolt Bridge`。
- 主控端在“隐私与安全性”的“辅助功能”和“输入监控”中允许 ThunderLink。被控端只需辅助功能。主控端连接时会核对 macOS 实际交给应用的按键事件类型。
- 当前构建使用固定的本地代码签名证书。首次迁移时需要批准新身份，后续更新需沿用同一证书和应用标识。
- 固定安装位置是 `/Applications/ThunderLink.app`。

## 构建

需要 macOS 和支持 Swift Testing 的 Swift 工具链；本版本使用 Apple Swift 6.1.2 验证，可使用相应的 Xcode Command Line Tools。

```bash
git clone https://github.com/sunnykaibai/thunderlink.git
cd thunderlink
swift test -j 2
zsh scripts/build-app.sh release
```

构建机必须有对应证书与私钥，并将该证书的 40 位 SHA-1 指纹保存到 `~/Library/Application Support/ThunderLink/Signing/identity.sha1`。接收安装包的 Mac 不需要私钥。

构建产物：

- `dist/ThunderLink.app`
- `dist/ThunderLink.zip`

构建脚本限制为 2 个编译任务，按当前 Mac 的架构生成安装包。本次安装包为 Apple Silicon（arm64），Intel Mac 需要在对应架构下构建。构建和测试不会启动 App 或注入真实键鼠事件。

## 两台 Mac 的使用顺序

1. 把 `ThunderLink.zip` 复制到两台 Mac，解压后把 `ThunderLink.app` 放入 `/Applications`。这个版本使用本地签名。
2. 在被控端选择“允许这台 Mac 被控制”，授予辅助功能权限，重新打开 App，然后点击“开始接收”。
3. 在主控端选择“控制另一台 Mac”，在 macOS 首次提示时授予辅助功能和输入监控权限。
4. 选择自动发现的对端，输入被控端显示的 6 位配对码，选择对端位于左边还是右边，然后点击“连接”。
5. 松开所有按键和鼠标按钮，把主控端指针移出所选屏幕边缘。指针进入被控端；移回相反边缘，或按 `Control + Option + Escape`，输入回到主控端。

## 验证和内存检查

自动测试覆盖协议编解码、消息大小限制、队列溢出、单次任务预约、回环 TCP 关闭与错误配对、握手超时、旧协议兼容、输入状态清理、双击和右键拖动。输入注入测试把事件交给内存中的测试回调，不会向系统发布事件。

可单独运行无网络、无输入注入的内存检查：

```bash
swiftc -O Sources/ThunderLink/AppTrackpadGesture.swift Sources/ThunderLink/WireMessage.swift Sources/ThunderLink/OutboundMessageQueue.swift Tools/MemoryProbe.swift -o /tmp/thunderlink-memory-probe
/tmp/thunderlink-memory-probe
```

检查会暂停消费，提交 100 万个模拟事件，并验证队列峰值、处理任务预约数和内存增长。它验证积压控制，不代表完整 App 在两台 Mac 上长期运行的内存表现。已执行的检查和结果见[验证记录](docs/VALIDATION.md)。

## 使用边界

ThunderLink 不调用 Apple Universal Control 的私有协议，不传输剪贴板、文件拖放、任意原始触点、Touch ID 或所有厂商的媒体键扩展。被控端光标目前仍限制在主显示器。两台真实 Mac 上的休眠、锁屏、多显示器和高频游戏鼠标行为尚未完整验证。

传输内容是经过配对码验证的本地 TCP 消息，但尚未加密。监听端拒绝不经过 `bridge0` 的连接，适用于两台直接用雷电线连接的 Mac，不应部署到不受信任的共享网络。

配对码保存在当前用户的本地偏好设置中，可在接收端点击“更换”重新生成；请不要把配对码或未经检查的诊断输出发到公开 Issue。

## 许可证

代码以 [MIT License](LICENSE) 发布。
