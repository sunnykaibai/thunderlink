import CoreGraphics

/// Holds the cursor at the transfer edge even when ThunderLink is in the background.
/// Warping does not post mouse events; remote motion must use the captured event's deltas.
final class LocalCursorLock {
    private let warp: (CGPoint) -> CGError
    private(set) var anchor: CGPoint?

    init(warp: @escaping (CGPoint) -> CGError = CGWarpMouseCursorPosition) {
        self.warp = warp
    }

    func acquire(at point: CGPoint, in bounds: CGRect) -> Bool {
        // Stay just inside the display so an adjacent screen or hot corner cannot
        // take over the parked cursor. Small bounds still clamp to a valid pixel.
        let insetX = min(4, (bounds.width - 1) / 2)
        let insetY = min(4, (bounds.height - 1) / 2)
        let point = CGPoint(
            x: min(max(point.x, bounds.minX + insetX), bounds.maxX - 1 - insetX),
            y: min(max(point.y, bounds.minY + insetY), bounds.maxY - 1 - insetY)
        )
        guard bounds.width >= 1, bounds.height >= 1, warp(point) == .success else {
            anchor = nil
            return false
        }
        anchor = point
        return true
    }

    func hold() -> Bool {
        guard let anchor else { return false }
        return warp(anchor) == .success
    }

    func release() {
        anchor = nil
    }
}
