import CoreGraphics

/// Recognizes the Dock's private three/four-finger swipe event stream on
/// macOS 15–26. It deliberately reduces a completed gesture to one system
/// arrow key instead of serializing private CGEvent data across the network.
struct DockSwipe {
    private enum Axis: Int64, Equatable {
        case horizontal = 1
        case vertical = 2
    }

    private enum State {
        case idle
        case local(Axis)
        case remote(Axis, progress: Double)
        case draining(Axis)
        case finishedRemote(Axis)
    }

    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    private static let dockControlEventType: UInt32 = 30
    private static let dockSwipeHIDType: Int64 = 23
    private static let minimumCommitProgress = 0.5
    private static let minimumCommitVelocity = 0.08

    private var state: State = .idle

    mutating func handle(_ event: CGEvent, remote: Bool) -> (consume: Bool, arrow: CGKeyCode?) {
        guard event.type.rawValue == Self.dockControlEventType,
              event.getIntegerValueField(Self.hidTypeField) == Self.dockSwipeHIDType,
              let axis = Axis(rawValue: event.getIntegerValueField(Self.axisField)),
              let phase = Phase(rawValue: event.getIntegerValueField(Self.phaseField)) else {
            return (false, nil)
        }

        if !remote, case .remote(let activeAxis, _) = state {
            state = .draining(activeAxis)
        }

        let progress = Self.progress(in: event)
        switch phase {
        case .began:
            if remote {
                state = .remote(axis, progress: progress)
                return (true, nil)
            }
            state = .local(axis)
            return (false, nil)

        case .changed:
            switch state {
            case .remote(axis, _):
                state = .remote(axis, progress: progress)
                return (true, nil)
            case .draining(axis), .finishedRemote(axis):
                return (true, nil)
            case .local(axis):
                return (false, nil)
            default:
                return (false, nil)
            }

        case .ended, .cancelled:
            switch state {
            case .remote(axis, let previousProgress):
                state = .finishedRemote(axis)
                guard phase == .ended else { return (true, nil) }
                let finalProgress = progress == 0 ? previousProgress : progress
                return (true, Self.arrow(axis: axis, progress: finalProgress, event: event))
            case .draining(axis):
                state = .finishedRemote(axis)
                return (true, nil)
            case .finishedRemote(axis):
                return (true, nil)
            case .local(axis):
                state = .idle
                return (false, nil)
            default:
                return (false, nil)
            }
        }
    }

    /// Stops a remotely-owned gesture from leaking its remaining frames to the
    /// local Dock after the pointer has returned to this Mac.
    mutating func release() {
        if case .remote(let axis, _) = state {
            state = .draining(axis)
        }
    }

    private static func arrow(axis: Axis, progress: Double, event: CGEvent) -> CGKeyCode? {
        let velocityField = axis == .horizontal ? velocityXField : velocityYField
        let velocity = event.getDoubleValueField(velocityField)
        let meaningfulVelocity = velocity.isFinite && abs(velocity) >= minimumCommitVelocity
        let meaningfulProgress = progress.isFinite && abs(progress) >= minimumCommitProgress

        if meaningfulVelocity, meaningfulProgress,
           (velocity > 0) != (progress > 0) {
            return nil
        }
        let direction: Double
        if meaningfulVelocity {
            direction = velocity
        } else if meaningfulProgress {
            direction = progress
        } else {
            return nil
        }

        switch axis {
        case .horizontal:
            return direction > 0 ? 124 : 123 // Right / Left
        case .vertical:
            return direction > 0 ? 126 : 125 // Up / Down
        }
    }

    private static func progress(in event: CGEvent) -> Double {
        let direct = event.getDoubleValueField(progressField)
        if direct.isFinite, direct != 0 { return direct }

        let encoded = UInt32(truncatingIfNeeded: event.getIntegerValueField(encodedProgressField))
        let decoded = Double(Float(bitPattern: encoded))
        return decoded.isFinite ? decoded : 0
    }

    private static func field(_ rawValue: UInt32) -> CGEventField {
        CGEventField(rawValue: rawValue)!
    }

    private static let hidTypeField = field(110)
    private static let axisField = field(123)
    private static let progressField = field(124)
    private static let velocityXField = field(129)
    private static let velocityYField = field(130)
    private static let phaseField = field(132)
    private static let encodedProgressField = field(135)
}
