import CoreGraphics

/// Converts hardware button events into one remote click sequence. WindowServer's
/// click count is global, so the first click after a handoff may continue a
/// sequence whose earlier clicks were local. This state rebases that first click
/// while retaining genuine double and triple clicks made on the remote Mac.
struct RemoteClicks {
    private struct PreviousDown {
        let button: Int
        let hardwareCount: Int
        let forwardedCount: Int
    }

    private static let movementThresholdSquared = 16.0
    private static let modifierSideBits: UInt64 = 0x0000_207f
    private static let modifierMaskRawValue: UInt64 = modifierSideBits
        | CGEventFlags.maskAlphaShift.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    static var modifierMask: CGEventFlags {
        CGEventFlags(rawValue: modifierMaskRawValue)
    }

    private var previousDown: PreviousDown?
    private var pairedUpCounts: [Int: Int] = [:]
    private var motionX = 0.0
    private var motionY = 0.0

    mutating func message(type: CGEventType, event: CGEvent) -> WireMessage? {
        guard let button = Self.buttonNumber(type: type, event: event) else { return nil }
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown

        let count: Int
        if isDown {
            let hardwareCount = Self.validClickCount(event)
            let continuesSequence = previousDown?.button == button
                && pairedUpCounts[button] == nil
                && previousDown.map { hardwareCount == $0.hardwareCount + 1 } == true
            if continuesSequence, let previousDown {
                count = previousDown.forwardedCount + 1
            } else {
                count = 1
            }
            previousDown = PreviousDown(
                button: button,
                hardwareCount: hardwareCount,
                forwardedCount: count
            )
            pairedUpCounts[button] = count
            motionX = 0
            motionY = 0
        } else {
            // A button-up still has to reach the peer even when its click-state
            // metadata is malformed or the corresponding down preceded a reset.
            count = pairedUpCounts.removeValue(forKey: button)
                ?? Self.validClickCount(event)
        }

        return WireMessage(
            type: .mouseButton,
            eventKind: isDown ? "down" : "up",
            flags: event.flags.rawValue & Self.modifierMask.rawValue,
            button: button,
            clickCount: count
        )
    }

    mutating func move(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        guard previousDown != nil else { return }
        motionX += dx
        motionY += dy
        if hasAppreciableMotion { previousDown = nil }
    }

    private var hasAppreciableMotion: Bool {
        motionX * motionX + motionY * motionY >= Self.movementThresholdSquared
    }

    private static func validClickCount(_ event: CGEvent) -> Int {
        let raw = event.getIntegerValueField(.mouseEventClickState)
        guard (1...Int64(Int32.max)).contains(raw) else { return 1 }
        return Int(raw)
    }

    static func buttonNumber(type: CGEventType, event: CGEvent) -> Int? {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return 0
        case .rightMouseDown, .rightMouseUp:
            return 1
        case .otherMouseDown, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            return (2...31).contains(button) ? Int(button) : nil
        default:
            return nil
        }
    }
}
