import CoreGraphics

struct InputState {
    private(set) var pressedButtons = Set<Int>()
    private(set) var pressedKeys = Set<CGKeyCode>()
    private var suppressedButtons = Set<Int>()
    private var suppressedKeys = Set<CGKeyCode>()

    var hasPressedInput: Bool {
        !pressedButtons.isEmpty || !pressedKeys.isEmpty
    }

    var hasSuppressedInput: Bool {
        !suppressedButtons.isEmpty || !suppressedKeys.isEmpty
    }

    func capturesRightOption(_ key: CGKeyCode, controllingRemote: Bool) -> Bool {
        key == 61 && (controllingRemote || suppressedKeys.contains(key))
    }

    func shouldSuppressDrag(button: Int) -> Bool {
        suppressedButtons.contains(button)
    }

    @discardableResult
    mutating func observeButton(_ button: Int, isDown: Bool) -> Bool {
        guard (0..<32).contains(button) else { return false }
        let shouldSuppress = suppressedButtons.contains(button)
        if isDown {
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
            suppressedButtons.remove(button)
        }
        return shouldSuppress
    }

    @discardableResult
    mutating func observeKey(_ key: CGKeyCode, kind: String, flags: CGEventFlags) -> Bool {
        guard key <= 255 else { return false }
        let shouldSuppress = suppressedKeys.contains(key)
        switch kind {
        case "down":
            pressedKeys.insert(key)
        case "up":
            pressedKeys.remove(key)
            suppressedKeys.remove(key)
        case "flags":
            guard let isDown = Self.modifierIsDown(key: key, flags: flags) else {
                return false
            }
            if isDown {
                pressedKeys.insert(key)
            } else {
                pressedKeys.remove(key)
                suppressedKeys.remove(key)
            }
        default:
            return false
        }
        return shouldSuppress
    }

    mutating func suppressPressedInputUntilRelease() {
        suppressedButtons.formUnion(pressedButtons)
        suppressedKeys.formUnion(pressedKeys)
    }

    mutating func reconcilePhysicalState(with snapshot: InputState) {
        pressedButtons = snapshot.pressedButtons
        pressedKeys = snapshot.pressedKeys
        suppressedButtons.formIntersection(pressedButtons)
        suppressedKeys.formIntersection(pressedKeys)
    }

    func allowsTransfer(eventFlags: CGEventFlags, physicalInputPressed: Bool) -> Bool {
        let transientModifiers: CGEventFlags = [
            .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn
        ]
        return !hasPressedInput
            && eventFlags.intersection(transientModifiers).isEmpty
            && !physicalInputPressed
    }

    mutating func removeAll() {
        pressedButtons.removeAll()
        pressedKeys.removeAll()
        suppressedButtons.removeAll()
        suppressedKeys.removeAll()
    }

    static let controlKeys: [CGKeyCode] = [59, 62]

    /// A click or ordinary key carries the modifier snapshot for that event.
    /// Recover a missed Control transition before forwarding the input it affects.
    mutating func reconcileControls(flags: CGEventFlags, send: (WireMessage) -> Void) {
        let hasControl = flags.contains(.maskControl)
        let sideBits = flags.rawValue & 0x2001
        let anyTracked = pressedKeys.contains(59) || pressedKeys.contains(62)
        for key in Self.controlKeys {
            let held = pressedKeys.contains(key)
            let desired: Bool
            if !hasControl {
                desired = false
            } else if sideBits != 0 {
                desired = Self.modifierIsDown(key: key, flags: flags) == true
            } else {
                // Preserve a known side when the device supplies only aggregate flags.
                desired = anyTracked ? held : key == 59
            }
            guard desired != held else { continue }
            let kind = desired ? "down" : "up"
            observeKey(key, kind: kind, flags: flags)
            send(WireMessage(type: .key, keyCode: key, eventKind: kind, flags: flags.rawValue))
        }
    }

    static func isEmergencyRelease(
        key: CGKeyCode,
        kind: String,
        flags: CGEventFlags
    ) -> Bool {
        key == 53 && kind == "down"
            && flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
    }

    private static func modifierIsDown(key: CGKeyCode, flags: CGEventFlags) -> Bool? {
        // CGEvent flags retain device-specific bits, which are needed when both
        // left and right variants of the same modifier are held simultaneously.
        let raw = flags.rawValue
        let descriptor: (side: UInt64, family: UInt64, aggregate: CGEventFlags)?
        switch key {
        case 55: descriptor = (0x0000_0008, 0x0000_0018, .maskCommand)
        case 54: descriptor = (0x0000_0010, 0x0000_0018, .maskCommand)
        case 56: descriptor = (0x0000_0002, 0x0000_0006, .maskShift)
        case 60: descriptor = (0x0000_0004, 0x0000_0006, .maskShift)
        case 58: descriptor = (0x0000_0020, 0x0000_0060, .maskAlternate)
        case 61: descriptor = (0x0000_0040, 0x0000_0060, .maskAlternate)
        case 59: descriptor = (0x0000_0001, 0x0000_2001, .maskControl)
        case 62: descriptor = (0x0000_2000, 0x0000_2001, .maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        // Caps Lock reports a latched state rather than a physical hold. Keeping
        // it in pressedKeys would prevent transfers for as long as Caps Lock is on.
        case 57: return nil
        default: return nil
        }
        guard let descriptor else { return nil }
        if raw & descriptor.family != 0 {
            return raw & descriptor.side != 0
        }
        return flags.contains(descriptor.aggregate)
    }
}
