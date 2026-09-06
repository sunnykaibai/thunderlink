import AppKit
import CoreGraphics

final class InputInjector {
    var onReleaseRequested: (() -> Void)?

    private var active = false
    private var edge: TransferEdge = .right
    private var position = CGPoint.zero
    private var inputState = InputState()
    private let source = CGEventSource(stateID: .hidSystemState)
    private let eventPoster: (CGEvent) -> Void
    private let primaryBounds: () -> CGRect?

    init(
        eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        primaryBounds: @escaping () -> CGRect? = { DisplayGeometry.primary()?.bounds }
    ) {
        self.eventPoster = eventPoster
        self.primaryBounds = primaryBounds
    }

    func activate(edge: TransferEdge) {
        self.edge = edge
        guard let bounds = primaryBounds() else {
            onReleaseRequested?()
            return
        }
        position = CGPoint(
            x: edge == .right ? bounds.minX + 3 : bounds.maxX - 3,
            y: bounds.midY
        )
        active = true
        postMouseMove()
    }

    func handle(_ message: WireMessage) {
        switch message.type {
        case .activate:
            activate(edge: message.edge ?? edge)
        case .mouseMove:
            guard active else { return }
            move(deltaX: message.deltaX ?? 0, deltaY: message.deltaY ?? 0)
        case .mouseButton:
            guard active else { return }
            postButton(message)
        case .scroll:
            guard active else { return }
            postScroll(message)
        case .key:
            guard active else { return }
            postKey(message)
        case .release:
            releaseAll()
        default: break
        }
    }

    func releaseAll() {
        guard active || inputState.hasPressedInput else { return }
        clampPositionToCurrentDisplay()
        for key in inputState.pressedKeys {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            event?.flags = []
            if let event { eventPoster(event) }
        }
        for button in inputState.pressedButtons {
            let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
            let type = upType(for: button)
            if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton) {
                eventPoster(event)
            }
        }
        inputState.removeAll()
        active = false
    }

    private func move(deltaX: Double, deltaY: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        guard let bounds = primaryBounds() else {
            releaseAll()
            onReleaseRequested?()
            return
        }
        let candidate = CGPoint(x: position.x + deltaX, y: position.y + deltaY)
        let returning = edge == .right
            ? candidate.x <= bounds.minX
            : candidate.x >= bounds.maxX - 1
        if returning {
            releaseAll()
            onReleaseRequested?()
            return
        }
        position.x = min(max(candidate.x, bounds.minX), bounds.maxX - 1)
        position.y = min(max(candidate.y, bounds.minY), bounds.maxY - 1)
        postMouseMove()
    }

    private func postMouseMove() {
        clampPositionToCurrentDisplay()
        let type: CGEventType
        let buttonNumber: Int
        if inputState.pressedButtons.contains(0) {
            type = .leftMouseDragged
            buttonNumber = 0
        } else if inputState.pressedButtons.contains(1) {
            type = .rightMouseDragged
            buttonNumber = 1
        } else if let other = inputState.pressedButtons.min() {
            type = .otherMouseDragged
            buttonNumber = other
        } else {
            type = .mouseMoved
            buttonNumber = 0
        }
        let button = CGMouseButton(rawValue: UInt32(buttonNumber)) ?? .left
        if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) {
            eventPoster(event)
        }
    }

    private func postButton(_ message: WireMessage) {
        clampPositionToCurrentDisplay()
        let number = message.button ?? 0
        guard (0..<32).contains(number) else { return }
        guard let kind = message.eventKind, kind == "down" || kind == "up" else { return }
        let isDown = kind == "down"
        inputState.observeButton(number, isDown: isDown)
        let button = CGMouseButton(rawValue: UInt32(number)) ?? .left
        let type = isDown ? downType(for: number) : upType(for: number)
        if let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) {
            if let clickCount = message.clickCount,
               clickCount >= 0,
               clickCount <= Int(Int32.max) {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            }
            eventPoster(event)
        }
    }

    private func postScroll(_ message: WireMessage) {
        guard let vertical = Self.scrollValue(message.scrollY),
              let horizontal = Self.scrollValue(message.scrollX) else { return }
        if let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) {
            eventPoster(event)
        }
    }

    private func postKey(_ message: WireMessage) {
        guard let rawKey = message.keyCode else { return }
        let key = CGKeyCode(rawKey)
        guard key <= 255 else { return }
        guard let kind = message.eventKind,
              kind == "down" || kind == "up" || kind == "flags" else { return }
        let flags = CGEventFlags(rawValue: message.flags ?? 0)
        inputState.observeKey(key, kind: kind, flags: flags)
        let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: key,
            keyDown: kind == "flags" ? inputState.pressedKeys.contains(key) : kind != "up"
        )
        event?.flags = flags
        if kind == "flags" { event?.type = .flagsChanged }
        if let event { eventPoster(event) }
    }

    private func downType(for button: Int) -> CGEventType {
        button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
    }

    private func upType(for button: Int) -> CGEventType {
        button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
    }

    private func clampPositionToCurrentDisplay() {
        guard let bounds = primaryBounds() else { return }
        position.x = min(max(position.x, bounds.minX), bounds.maxX - 1)
        position.y = min(max(position.y, bounds.minY), bounds.maxY - 1)
    }

    private static func scrollValue(_ value: Double?) -> Int32? {
        let value = value ?? 0
        guard value.isFinite else { return nil }
        let clamped = min(max(value, Double(Int32.min)), Double(Int32.max))
        return Int32(clamped.rounded(.towardZero))
    }
}
