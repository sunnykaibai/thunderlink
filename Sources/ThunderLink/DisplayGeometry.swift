import CoreGraphics

struct ActiveDisplay {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

enum DisplayGeometry {
    static func activeDisplays() -> [ActiveDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsActive(id) != 0, CGDisplayIsOnline(id) != 0 else { return nil }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return ActiveDisplay(id: id, bounds: bounds)
        }
    }

    static func containing(_ point: CGPoint) -> ActiveDisplay? {
        activeDisplays().first { $0.bounds.contains(point) }
    }

    static func primary() -> ActiveDisplay? {
        let displays = activeDisplays()
        let main = CGMainDisplayID()
        return displays.first(where: { $0.id == main }) ?? displays.first
    }

    static func current(_ id: CGDirectDisplayID?) -> ActiveDisplay? {
        guard let id else { return primary() }
        return activeDisplays().first(where: { $0.id == id }) ?? primary()
    }

    static func isOuterEdge(
        of display: ActiveDisplay,
        atY y: CGFloat,
        edge: TransferEdge,
        among displays: [ActiveDisplay]
    ) -> Bool {
        let probeX = edge == .right ? display.bounds.maxX + 0.5 : display.bounds.minX - 0.5
        let probe = CGPoint(x: probeX, y: y)
        return !displays.contains { candidate in
            candidate.id != display.id && candidate.bounds.contains(probe)
        }
    }
}
