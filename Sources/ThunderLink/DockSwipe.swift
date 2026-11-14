import CoreGraphics

/// Ownership is decided by the pointer when a swipe begins. Consume trailing
/// frames after a handoff so a gesture cannot finish on a different Mac.
struct DockSwipe {
    private enum State {
        case idle
        case remote(DesktopGestureFrame, native: Bool)
        case draining(DesktopGestureFrame.Axis)
    }

    struct Result {
        var consume: Bool
        var arrow: CGKeyCode? = nil
        var frame: DesktopGestureFrame? = nil
    }

    private var state: State = .idle

    mutating func handle(_ event: CGEvent, remote: Bool, native: Bool = false) -> Result {
        guard let frame = DesktopGestureFrame(capturing: event) else {
            return Result(consume: false)
        }
        if !remote { release() }

        if frame.phase == .began {
            guard remote, native || frame.axis != .pinch else {
                state = .idle
                return Result(consume: false)
            }
            state = .remote(frame, native: native)
            return Result(consume: true, frame: native ? frame : nil)
        }
        switch state {
        case .remote(let previous, let native) where previous.axis == frame.axis:
            if frame.phase == .changed {
                state = .remote(frame, native: native)
                return Result(consume: true, frame: native ? frame : nil)
            }
            state = .draining(frame.axis)
            if native { return Result(consume: true, frame: frame) }
            let progress = frame.offset == 0 ? previous.offset : frame.offset
            let arrow = frame.phase == .ended ? Self.arrow(frame, progress: progress) : nil
            return Result(consume: true, arrow: arrow)
        case .draining(let axis) where axis == frame.axis:
            return Result(consume: true)
        default:
            return Result(consume: false)
        }
    }

    func cancelNativeGesture() -> DesktopGestureFrame? {
        if case .remote(let frame, true) = state { return frame.cancellation }
        return nil
    }

    mutating func release() {
        if case .remote(let frame, _) = state { state = .draining(frame.axis) }
    }

    private static func arrow(_ frame: DesktopGestureFrame, progress: Double) -> CGKeyCode? {
        let velocity = frame.axis == .horizontal ? frame.velocityX : frame.velocityY
        let meaningfulVelocity = abs(velocity) >= 0.08
        let meaningfulProgress = abs(progress) >= 0.5
        guard meaningfulVelocity || meaningfulProgress else { return nil }
        if meaningfulVelocity && meaningfulProgress && (velocity > 0) != (progress > 0) {
            return nil
        }
        let direction = meaningfulVelocity ? velocity : progress
        switch frame.axis {
        case .horizontal: return direction > 0 ? 124 : 123
        case .vertical: return direction > 0 ? 126 : 125
        case .pinch: return nil
        }
    }
}
