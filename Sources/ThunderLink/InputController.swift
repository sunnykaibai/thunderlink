import AppKit
import CoreGraphics
import notify

final class InputController {
    var onSend: ((WireMessage) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    var supportsAppGestures = false
    var supportsDesktopGestures = false
    private var gestureTap: CFMachPort?
    private var gestureSource: CFRunLoopSource?
    private var dockSwipe = DockSwipe()

    var transferEdge: TransferEdge = .right
    private(set) var isReady = false
    private(set) var isControlling = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionTap: CFMachPort?
    private var rightOptionSource: CFRunLoopSource?
    private var tapNotificationToken: Int32?
    private var otherModifierTapIDs: Set<UInt32> = []
    private var lastRelease = Date.distantPast
    private var entryPoint = CGPoint.zero
    private var cursorDisplayID: CGDirectDisplayID?
    private var cursorHidden = false
    private var cursorDisassociated = false
    private var stopPending = false
    private var stopCleanupScheduled = false
    private let cursorLock = LocalCursorLock()
    private var localInputState = InputState()
    private let physicalInputSnapshot: () -> InputState

    init(physicalInputSnapshot: @escaping () -> InputState = InputController.readPhysicalInputState) {
        self.physicalInputSnapshot = physicalInputSnapshot
    }

    deinit {
        stopMonitoring(force: true)
        if cursorDisassociated { _ = CGAssociateMouseAndMouseCursorPosition(1) }
    }

    func startMonitoring() throws {
        // A pending drain uses the old tap. Replace it synchronously before
        // installing a fresh tap; held state remains tracked across the swap.
        stopMonitoring(force: true)
        localInputState.reconcilePhysicalState(with: physicalInputSnapshot())
        guard SystemPermissions.accessibilityGranted else { throw InputError.accessibilityRequired }

        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<InputController>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: pointer
        ) else {
            throw InputError.eventTapCreationFailed
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // macOS may create an active HID tap after removing keyDown and keyUp
        // from its mask. Check what the system installed before enabling transfers.
        guard let taps = Self.installedTaps() else {
            finishStoppingMonitoring()
            throw InputError.eventTapCreationFailed
        }
        guard taps.contains(where: {
            $0.tappingProcess == getpid() && $0.tapPoint == .cghidEventTap &&
            $0.options == .defaultTap && $0.enabled && Self.capturesKeyboard($0.eventsOfInterest)
        }) else {
            finishStoppingMonitoring()
            throw InputError.keyboardEventsUnavailable
        }
        if !installGestureTap() {
            // A gesture registration failure must not break an existing keyboard/mouse pair.
            ThunderLinkLog.input.error("Could not install trackpad session tap")
            onError?("触控板手势监听未能启动，键盘和鼠标仍可使用")
        }
        isReady = true
        var token: Int32 = 0
        if notify_register_dispatch(kCGNotifyEventTapAdded, &token, .main, { [weak self] _ in
            self?.refreshRightOptionTapIfNeeded()
        }) == NOTIFY_STATUS_OK {
            tapNotificationToken = token
        }
    }

    // WindowServer emits recognized gestures in the session stream. Keep the
    // existing HID tap for keys, mouse and scroll; these masks do not overlap.
    private func installGestureTap() -> Bool {
        let mask = (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<InputController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let frame = controller.dockSwipe.cancelNativeGesture() {
                        controller.onSend?(WireMessage(type: .desktopGesture, desktopGesture: frame))
                    }
                    controller.dockSwipe.release()
                    if let tap = controller.gestureTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return controller.handleGesture(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        gestureTap = tap
        gestureSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleGesture(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let result = dockSwipe.handle(event, remote: isControlling, native: supportsDesktopGestures && DesktopGestureFrame.isSupportedOnThisOS)
        if result.consume {
            if let frame = result.frame {
                if frame.phase == .ended {
                    ThunderLinkLog.input.info("Forwarded native desktop gesture on axis \(frame.axis.rawValue, privacy: .public)")
                }
                onSend?(WireMessage(type: .desktopGesture, desktopGesture: frame))
            } else if let key = result.arrow, isControlling, !localInputState.hasPressedInput {
                sendDesktopShortcut(key)
            }
            return nil
        }
        if isControlling, supportsAppGestures, let gesture = AppTrackpadGesture(capturing: event) {
            onSend?(WireMessage(type: .appGesture, appGesture: gesture))
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func sendDesktopShortcut(_ arrow: CGKeyCode) {
        let control = CGEventFlags.maskControl.rawValue | 0x01
        // On macOS, arrow key events include both the keypad and function-key
        // classification bits. Modifier transitions have neither.
        let arrowFlags = control | CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        onSend?(WireMessage(type: .key, keyCode: 59, eventKind: "flags", flags: control))
        onSend?(WireMessage(type: .key, keyCode: arrow, eventKind: "down", flags: arrowFlags))
        onSend?(WireMessage(type: .key, keyCode: arrow, eventKind: "up", flags: arrowFlags))
        onSend?(WireMessage(type: .key, keyCode: 59, eventKind: "flags", flags: 0))
        // Some apps hide the pointer on typing. Refresh it at the same position
        // after this trackpad-generated shortcut, including on older receivers.
        onSend?(WireMessage(type: .mouseMove, deltaX: 0, deltaY: 0))
        ThunderLinkLog.input.info("Forwarded desktop gesture using Control and arrow \(arrow, privacy: .public)")
    }

    // Input methods may install their own head filter after we connect. Take
    // priority for this shortcut on each transfer, without disturbing the
    // mouse tap whose callback is currently processing the crossing.
    private func installRightOptionTap() -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.rightOptionTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return controller.handle(type: type, event: event)
                }
                return controller.handleRightOption(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        removeRightOptionTap()
        rightOptionTap = tap
        rightOptionSource = source
        return true
    }

    private func handleRightOption(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard type == .flagsChanged, localInputState.capturesRightOption(key, controllingRemote: isControlling) else {
            return Unmanaged.passUnretained(event)
        }
        // The main tap never sees a consumed event. Share its forwarding and
        // held-key cleanup so the receiver gets exactly one transition.
        return handle(type: type, event: event)
    }

    private func removeRightOptionTap() {
        if let source = rightOptionSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = rightOptionTap { CFMachPortInvalidate(tap) }
        rightOptionTap = nil
        rightOptionSource = nil
    }

    private func refreshRightOptionTapIfNeeded() {
        guard isControlling, let current = Self.foreignModifierTapIDs() else { return }
        let hasNewFilter = !current.isSubset(of: otherModifierTapIDs)
        otherModifierTapIDs = current
        guard hasNewFilter else { return }
        if !installRightOptionTap() {
            onSend?(WireMessage(type: .release))
            releaseFromRemote()
            onError?("无法接管右 Option，已恢复本机控制")
        }
    }

    static func capturesKeyboard(_ mask: CGEventMask) -> Bool {
        let required = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (1 << $1.rawValue)
        }
        return mask & required == required
    }

    private static func installedTaps() -> ArraySlice<CGEventTapInformation>? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 16)
        let capacity = UInt32(taps.count)
        guard CGGetEventTapList(capacity, &taps, &count) == .success, count <= capacity else { return nil }
        return taps.prefix(Int(count))
    }

    // The system notification includes our own new tap. Compare foreign IDs
    // rather than depending on an undocumented order in CGGetEventTapList.
    private static func foreignModifierTapIDs() -> Set<UInt32>? {
        guard let taps = installedTaps() else { return nil }
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        return Set(taps.filter {
            $0.tappingProcess != getpid() && $0.tapPoint == .cghidEventTap &&
            $0.eventsOfInterest & mask != 0
        }.map(\.eventTapID))
    }

    func stopMonitoring(force: Bool = false) {
        releaseFromRemote()
        reassociateLocalCursor()
        isReady = false
        if !force, localInputState.hasSuppressedInput {
            // Keep the tap only long enough to consume repeats and matching up
            // events from inputs whose down events were sent to the remote Mac.
            stopPending = true
            return
        }
        finishStoppingMonitoring()
    }

    private func finishStoppingMonitoring() {
        if let gestureSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), gestureSource, .commonModes) }
        if let gestureTap { CFMachPortInvalidate(gestureTap) }
        gestureSource = nil
        gestureTap = nil
        dockSwipe = DockSwipe()
        if let token = tapNotificationToken { notify_cancel(token) }
        tapNotificationToken = nil
        removeRightOptionTap()
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        runLoopSource = nil
        stopPending = false
        stopCleanupScheduled = false
        isReady = false
    }

    func releaseFromRemote() {
        cursorLock.release()
        guard isControlling else { return }
        dockSwipe.release()
        // Key-down events were consumed while remote control was active. Keep
        // consuming repeats and the matching physical up events after returning,
        // otherwise the local app can receive input without a corresponding down.
        localInputState.suppressPressedInputUntilRelease()
        isControlling = false
        lastRelease = Date()
        reassociateLocalCursor()
        restoreCursorAndPosition()
        onActiveChanged?(false)
    }

    private func restoreCursorAndPosition() {
        // A delayed restore from an earlier transfer must not move or reveal the
        // cursor after a new transfer has started.
        guard !isControlling else { return }
        guard let display = DisplayGeometry.current(cursorDisplayID) else {
            if cursorHidden {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.restoreCursorAndPosition()
                }
            }
            return
        }
        if cursorHidden {
            guard CGDisplayShowCursor(display.id) == .success else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.restoreCursorAndPosition()
                }
                return
            }
            cursorHidden = false
        }
        cursorDisplayID = nil
        let bounds = display.bounds
        let returnY = bounds.contains(entryPoint) ? entryPoint.y : bounds.midY
        let point = CGPoint(
            x: transferEdge == .right ? bounds.maxX - 4 : bounds.minX + 4,
            y: min(max(returnY, bounds.minY), bounds.maxY - 1)
        )
        CGWarpMouseCursorPosition(point)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isControlling {
                onSend?(WireMessage(type: .release))
                releaseFromRemote()
                onError?("输入监听中断，已恢复本机控制；请重新移到边缘连接")
            }
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let shouldSuppressLocally = observeLocalInput(type: type, event: event)
        if stopPending, !localInputState.hasSuppressedInput, !stopCleanupScheduled {
            stopCleanupScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stopCleanupScheduled = false
                guard self.stopPending, !self.localInputState.hasSuppressedInput else { return }
                self.finishStoppingMonitoring()
            }
        }

        if type == .keyDown,
           InputState.isEmergencyRelease(
               key: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
               kind: "down",
               flags: event.flags
           ),
           isControlling {
            onSend?(WireMessage(type: .release))
            releaseFromRemote()
            return nil
        }

        if !isControlling, shouldSuppressLocally {
            return nil
        }

        if !isControlling, isMouseMovement(type), shouldActivate(type: type, event: event) {
            guard let display = DisplayGeometry.containing(event.location) ?? DisplayGeometry.primary() else {
                return Unmanaged.passUnretained(event)
            }
            guard cursorLock.acquire(at: event.location, in: display.bounds) else {
                lastRelease = Date()
                ThunderLinkLog.input.error("local cursor lock failed; remote activation refused")
                onError?("无法固定本机光标，未开始远端控制")
                return Unmanaged.passUnretained(event)
            }
            otherModifierTapIDs = Self.foreignModifierTapIDs() ?? []
            guard installRightOptionTap() else {
                cursorLock.release()
                lastRelease = Date()
                onError?("无法接管右 Option，未开始远端控制")
                return Unmanaged.passUnretained(event)
            }
            isControlling = true
            entryPoint = event.location
            cursorDisplayID = display.id
            // Association and hiding are foreground-only APIs. Background control
            // always relies on cursorLock, regardless of their return codes.
            if NSApplication.shared.isActive {
                if !cursorDisassociated {
                    cursorDisassociated = CGAssociateMouseAndMouseCursorPosition(0) == .success
                }
                // A previous Show failure still owns one hide count. Do not
                // increment it again before that outstanding hide is balanced.
                if !cursorHidden {
                    cursorHidden = CGDisplayHideCursor(display.id) == .success
                }
            }
            ThunderLinkLog.input.notice("remote control started; local cursor pinned, foreground=\(NSApplication.shared.isActive, privacy: .public)")
            for message in Self.activationMessages(edge: transferEdge) { onSend?(message) }
            onActiveChanged?(true)
            return nil
        }
        guard isControlling else { return Unmanaged.passUnretained(event) }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Capture hardware deltas before repositioning the local cursor. Never
            // derive remote movement from absolute coordinates after a warp.
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            guard cursorLock.hold() else {
                ThunderLinkLog.input.error("local cursor lock lost; releasing remote control")
                onSend?(WireMessage(type: .release))
                releaseFromRemote()
                onError?("无法继续固定本机光标，已停止远端控制")
                return nil
            }
            onSend?(WireMessage(
                type: .mouseMove,
                deltaX: Double(dx),
                deltaY: Double(dy)
            ))
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            onSend?(WireMessage(
                type: .mouseButton,
                eventKind: isButtonDown(type) ? "down" : "up",
                button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState))
            ))
        case .scrollWheel:
            onSend?(ScrollGesture.message(from: event))
        case .keyDown, .keyUp, .flagsChanged:
            onSend?(WireMessage(
                type: .key,
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                eventKind: type == .keyUp ? "up" : (type == .flagsChanged ? "flags" : "down"),
                flags: event.flags.rawValue
            ))
        default: break
        }
        return nil
    }

    static func activationMessages(edge: TransferEdge) -> [WireMessage] {
        // Existing receivers enter only three points from the return edge.
        // Move inward once on handoff so a small reversal does not hand back.
        [
            WireMessage(type: .activate, edge: edge),
            WireMessage(type: .mouseMove, deltaX: edge == .right ? 24 : -24, deltaY: 0)
        ]
    }

    private func shouldActivate(type: CGEventType, event: CGEvent) -> Bool {
        guard isReady,
              type == .mouseMoved,
              Date().timeIntervalSince(lastRelease) > 0.7 else { return false }
        let location = event.location
        guard let display = DisplayGeometry.containing(location) ?? DisplayGeometry.primary() else {
            return false
        }
        let bounds = display.bounds
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let movingOutward = transferEdge == .right
            ? location.x >= bounds.maxX - 1 && dx > 0
            : location.x <= bounds.minX + 1 && dx < 0
        guard movingOutward && DisplayGeometry.isOuterEdge(
            of: display,
            atY: location.y,
            edge: transferEdge,
            among: DisplayGeometry.activeDisplays()
        ) else { return false }
        let physicalState = physicalInputSnapshot()
        return localInputState.allowsTransfer(
            eventFlags: event.flags,
            physicalInputPressed: physicalState.hasPressedInput
        )
    }

    private func observeLocalInput(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return localInputState.observeButton(
                Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                isDown: true
            )
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return localInputState.observeButton(
                Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                isDown: false
            )
        case .leftMouseDragged:
            return localInputState.shouldSuppressDrag(button: 0)
        case .rightMouseDragged:
            return localInputState.shouldSuppressDrag(button: 1)
        case .otherMouseDragged:
            return localInputState.shouldSuppressDrag(
                button: Int(event.getIntegerValueField(.mouseEventButtonNumber))
            )
        case .keyDown, .keyUp, .flagsChanged:
            let kind = type == .keyUp ? "up" : (type == .flagsChanged ? "flags" : "down")
            return localInputState.observeKey(
                CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                kind: kind,
                flags: event.flags
            )
        default:
            return false
        }
    }

    static func readPhysicalInputState() -> InputState {
        var state = InputState()
        for rawButton in UInt32(0)..<32 {
            if let button = CGMouseButton(rawValue: rawButton),
               CGEventSource.buttonState(.combinedSessionState, button: button) {
                state.observeButton(Int(rawButton), isDown: true)
            }
        }
        for key in CGKeyCode(0)...255 where key != 57 {
            if CGEventSource.keyState(.combinedSessionState, key: key) {
                state.observeKey(key, kind: "down", flags: [])
            }
        }
        return state
    }

    private func reassociateLocalCursor() {
        guard cursorDisassociated else { return }
        if CGAssociateMouseAndMouseCursorPosition(1) == .success {
            cursorDisassociated = false
        } else {
            ThunderLinkLog.input.error("failed to reassociate the local mouse cursor")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.isControlling else { return }
                self.reassociateLocalCursor()
            }
        }
    }

    private func isMouseMovement(_ type: CGEventType) -> Bool {
        [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
    }

    private func isButtonDown(_ type: CGEventType) -> Bool {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    enum InputError: LocalizedError {
        case accessibilityRequired
        case keyboardEventsUnavailable
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "请先授予辅助功能权限"
            case .keyboardEventsUnavailable: return "普通按键监听未生效。请在本机允许 ThunderLink 输入监控，再重新连接。"
            case .eventTapCreationFailed: return "无法创建全局输入监听，请检查权限后重启 App"
            }
        }
    }
}
