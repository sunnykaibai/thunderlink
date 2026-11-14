import CoreGraphics

/// A bounded, wire-safe representation of the application gestures whose
/// type-29 CGEvent encoding is exercised by Mac Mouse Fix's TouchSimulator.
///
/// This intentionally reads individual allowlisted fields. It never copies or
/// decodes an event's opaque backing data.
struct AppTrackpadGesture: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case magnify
        case rotate
        case smartMagnify
        case navigationSwipe
    }

    enum Phase: Int64, Codable, Equatable {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    enum SwipeDirection: Int64, Codable, Equatable {
        case left = 4
        case right = 8
    }

    let kind: Kind
    let phase: Phase?
    let amount: Double?
    let swipeDirection: SwipeDirection?

    private enum CodingKeys: String, CodingKey {
        case kind
        case phase
        case amount
        case swipeDirection
    }

    init?(capturing event: CGEvent) {
        guard event.type.rawValue == Self.gestureEventType else { return nil }

        let kind: Kind
        let phase: Phase?
        let amount: Double?
        let swipeDirection: SwipeDirection?

        switch event.getIntegerValueField(Self.hidTypeField) {
        case Self.rotationHIDType:
            guard let capturedPhase = Phase(
                rawValue: event.getIntegerValueField(Self.phaseField)
            ) else { return nil }
            kind = .rotate
            phase = capturedPhase
            amount = event.getDoubleValueField(Self.rotationField)
            swipeDirection = nil

        case Self.zoomHIDType:
            guard let capturedPhase = Phase(
                rawValue: event.getIntegerValueField(Self.phaseField)
            ) else { return nil }
            kind = .magnify
            phase = capturedPhase
            amount = event.getDoubleValueField(Self.magnificationField)
            swipeDirection = nil

        case Self.navigationSwipeHIDType:
            guard let capturedPhase = Phase(
                rawValue: event.getIntegerValueField(Self.phaseField)
            ) else { return nil }
            let rawDirection = event.getIntegerValueField(Self.swipeDirectionField)
            kind = .navigationSwipe
            phase = capturedPhase
            amount = nil
            swipeDirection = SwipeDirection(rawValue: rawDirection)

        case Self.zoomToggleHIDType:
            kind = .smartMagnify
            phase = nil
            amount = nil
            swipeDirection = nil

        default:
            return nil
        }

        guard Self.isValid(
            kind: kind,
            phase: phase,
            amount: amount,
            swipeDirection: swipeDirection
        ) else { return nil }

        self.kind = kind
        self.phase = phase
        self.amount = amount
        self.swipeDirection = swipeDirection
    }

    var closingFrame: Self? {
        switch kind {
        case .magnify, .rotate:
            return Self(kind: kind, phase: .cancelled, amount: 0, swipeDirection: nil)
        case .navigationSwipe:
            return Self(kind: kind, phase: .ended, amount: nil, swipeDirection: nil)
        case .smartMagnify:
            return nil
        }
    }

    func makeEvent(at point: CGPoint) -> CGEvent? {
        guard point.x.isFinite, point.y.isFinite,
              Self.isValid(
                kind: kind,
                phase: phase,
                amount: amount,
                swipeDirection: swipeDirection
              ),
              let event = CGEvent(source: nil),
              let type = CGEventType(rawValue: Self.gestureEventType) else {
            return nil
        }

        event.type = type
        event.location = point

        switch kind {
        case .magnify:
            event.setIntegerValueField(Self.hidTypeField, value: Self.zoomHIDType)
            event.setIntegerValueField(Self.phaseField, value: phase!.rawValue)
            event.setDoubleValueField(Self.magnificationField, value: amount!)

        case .rotate:
            event.setIntegerValueField(Self.hidTypeField, value: Self.rotationHIDType)
            event.setIntegerValueField(Self.phaseField, value: phase!.rawValue)
            event.setDoubleValueField(Self.rotationField, value: amount!)

        case .smartMagnify:
            event.setIntegerValueField(Self.hidTypeField, value: Self.zoomToggleHIDType)

        case .navigationSwipe:
            event.setIntegerValueField(Self.hidTypeField, value: Self.navigationSwipeHIDType)
            event.setIntegerValueField(Self.phaseField, value: phase!.rawValue)
            event.setIntegerValueField(
                Self.swipeDirectionField,
                value: swipeDirection?.rawValue ?? 0
            )
        }

        return event
    }

    private init(
        kind: Kind,
        phase: Phase?,
        amount: Double?,
        swipeDirection: SwipeDirection?
    ) {
        self.kind = kind
        self.phase = phase
        self.amount = amount
        self.swipeDirection = swipeDirection
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let phase = try values.decodeIfPresent(Phase.self, forKey: .phase)
        let amount = try values.decodeIfPresent(Double.self, forKey: .amount)
        let swipeDirection = try values.decodeIfPresent(
            SwipeDirection.self,
            forKey: .swipeDirection
        )
        guard Self.isValid(
            kind: kind,
            phase: phase,
            amount: amount,
            swipeDirection: swipeDirection
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid application trackpad gesture fields"
            ))
        }
        self.init(
            kind: kind,
            phase: phase,
            amount: amount,
            swipeDirection: swipeDirection
        )
    }

    private static func isValid(
        kind: Kind,
        phase: Phase?,
        amount: Double?,
        swipeDirection: SwipeDirection?
    ) -> Bool {
        switch kind {
        case .magnify:
            return phase != nil && bounded(amount, maximumMagnitude: 8)
                && swipeDirection == nil
        case .rotate:
            return phase != nil && bounded(amount, maximumMagnitude: 360)
                && swipeDirection == nil
        case .smartMagnify:
            return phase == nil && amount == nil && swipeDirection == nil
        case .navigationSwipe:
            guard amount == nil, let phase else { return false }
            switch phase {
            case .began:
                return swipeDirection != nil
            case .ended:
                return swipeDirection == nil
            case .changed, .cancelled:
                return false
            }
        }
    }

    private static func bounded(_ value: Double?, maximumMagnitude: Double) -> Bool {
        guard let value else { return false }
        return value.isFinite && abs(value) <= maximumMagnitude
    }

    private static func field(_ rawValue: UInt32) -> CGEventField {
        CGEventField(rawValue: rawValue)!
    }

    private static let gestureEventType: UInt32 = 29
    private static let rotationHIDType: Int64 = 5
    private static let zoomHIDType: Int64 = 8
    private static let navigationSwipeHIDType: Int64 = 16
    private static let zoomToggleHIDType: Int64 = 22

    private static let hidTypeField = field(110)
    private static let magnificationField = field(113)
    private static let rotationField = field(114)
    private static let swipeDirectionField = field(115)
    private static let phaseField = field(132)
}
