import CoreGraphics
import Foundation

/// A bounded, wire-safe representation of one WindowServer Dock-swipe frame.
/// Only the fields required to describe the gesture are copied. Opaque CGEvent
/// data is never serialized.
struct DesktopGestureFrame: Codable, Equatable {
    enum Axis: Int64, Codable, Equatable {
        case horizontal = 1
        case vertical = 2
        case pinch = 3
    }

    enum Phase: Int64, Codable, Equatable {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    let axis: Axis
    let phase: Phase
    let offset: Double
    let velocityX: Double
    let velocityY: Double
    let invertedFromDevice: Bool

    static var isSupportedOnThisOS: Bool {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return (13...26).contains(major)
    }

    init?(capturing event: CGEvent) {
        guard event.type.rawValue == Self.dockControlEventType,
              event.getIntegerValueField(Self.hidTypeField) == Self.dockSwipeHIDType,
              let axis = Axis(rawValue: event.getIntegerValueField(Self.axisField)),
              let phase = Phase(rawValue: event.getIntegerValueField(Self.phaseField)) else {
            return nil
        }

        let inverted = event.getIntegerValueField(Self.invertedField)
        guard inverted == 0 || inverted == 1 else { return nil }

        let directOffset = event.getDoubleValueField(Self.offsetField)
        let encodedOffset = UInt32(truncatingIfNeeded:
            event.getIntegerValueField(Self.encodedOffsetField)
        )
        let decodedOffset = Double(Float(bitPattern: encodedOffset))
        let offset = directOffset == 0 ? decodedOffset : directOffset

        self.init(
            axis: axis,
            phase: phase,
            offset: offset,
            velocityX: event.getDoubleValueField(Self.velocityXField),
            velocityY: event.getDoubleValueField(Self.velocityYField),
            invertedFromDevice: inverted == 1
        )
        guard Self.isValid(self) else { return nil }
    }

    private init(
        axis: Axis,
        phase: Phase,
        offset: Double,
        velocityX: Double,
        velocityY: Double,
        invertedFromDevice: Bool
    ) {
        self.axis = axis
        self.phase = phase
        self.offset = offset
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.invertedFromDevice = invertedFromDevice
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let frame = Self(
            axis: try values.decode(Axis.self, forKey: .axis),
            phase: try values.decode(Phase.self, forKey: .phase),
            offset: try values.decode(Double.self, forKey: .offset),
            velocityX: try values.decode(Double.self, forKey: .velocityX),
            velocityY: try values.decode(Double.self, forKey: .velocityY),
            invertedFromDevice: try values.decode(Bool.self, forKey: .invertedFromDevice)
        )
        guard Self.isValid(frame) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid desktop gesture frame"
            ))
        }
        self = frame
    }

    var cancellation: Self {
        Self(
            axis: axis,
            phase: .cancelled,
            offset: offset,
            velocityX: 0,
            velocityY: 0,
            invertedFromDevice: invertedFromDevice
        )
    }

    fileprivate func makeEvents(at point: CGPoint) -> (dock: CGEvent, marker: CGEvent)? {
        guard point.x.isFinite, point.y.isFinite, Self.isValid(self),
              let dock = CGEvent(source: nil),
              let marker = CGEvent(source: nil),
              let dockType = CGEventType(rawValue: Self.dockControlEventType),
              let markerType = CGEventType(rawValue: Self.gestureMarkerEventType) else {
            return nil
        }

        dock.type = dockType
        dock.location = point
        dock.setIntegerValueField(Self.hidTypeField, value: Self.dockSwipeHIDType)
        dock.setIntegerValueField(Self.phaseField, value: phase.rawValue)
        dock.setIntegerValueField(Self.redundantPhaseField, value: phase.rawValue)
        dock.setDoubleValueField(Self.offsetField, value: offset)
        dock.setIntegerValueField(
            Self.encodedOffsetField,
            value: Int64(UInt32(Float(offset).bitPattern))
        )
        dock.setDoubleValueField(Self.axisFloatField, value: Self.encodedAxis(axis))
        dock.setDoubleValueField(Self.redundantAxisFloatField, value: Self.encodedAxis(axis))
        dock.setIntegerValueField(Self.axisField, value: axis.rawValue)
        dock.setIntegerValueField(Self.redundantAxisField, value: axis.rawValue)
        dock.setIntegerValueField(Self.invertedField, value: invertedFromDevice ? 1 : 0)
        dock.setDoubleValueField(Self.eventCompatibilityField, value: Self.compatibilityValue)
        if phase == .ended || phase == .cancelled {
            dock.setDoubleValueField(Self.velocityXField, value: velocityX)
            dock.setDoubleValueField(Self.velocityYField, value: velocityY)
        }

        marker.type = markerType
        marker.location = point
        marker.setDoubleValueField(Self.eventCompatibilityField, value: Self.compatibilityValue)
        return (dock, marker)
    }

    private static func isValid(_ frame: Self) -> Bool {
        bounded(frame.offset, maximumMagnitude: 16)
            && bounded(frame.velocityX, maximumMagnitude: 10_000)
            && bounded(frame.velocityY, maximumMagnitude: 10_000)
    }

    private static func bounded(_ value: Double, maximumMagnitude: Double) -> Bool {
        value.isFinite && abs(value) <= maximumMagnitude
    }

    private static func encodedAxis(_ axis: Axis) -> Double {
        Double(Float(bitPattern: UInt32(axis.rawValue)))
    }

    private static func field(_ rawValue: UInt32) -> CGEventField {
        CGEventField(rawValue: rawValue)!
    }

    private static let gestureMarkerEventType: UInt32 = 29
    private static let dockControlEventType: UInt32 = 30
    private static let dockSwipeHIDType: Int64 = 23
    private static let compatibilityValue = 33_231.0

    private static let eventCompatibilityField = field(41)
    private static let hidTypeField = field(110)
    private static let axisFloatField = field(119)
    private static let axisField = field(123)
    private static let offsetField = field(124)
    private static let velocityXField = field(129)
    private static let velocityYField = field(130)
    private static let phaseField = field(132)
    private static let redundantPhaseField = field(134)
    private static let encodedOffsetField = field(135)
    private static let invertedField = field(136)
    private static let redundantAxisFloatField = field(139)
    private static let redundantAxisField = field(165)
}

/// Validates frame ordering and posts paired Dock-control and gesture-marker
/// events to the session stream.
final class DesktopGesturePlayback {
    private let eventPoster: (CGEvent) -> Void
    private var activeFrame: DesktopGestureFrame?

    init(eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.eventPoster = eventPoster
    }

    @discardableResult
    func handle(_ frame: DesktopGestureFrame, at position: CGPoint) -> Bool {
        guard DesktopGestureFrame.isSupportedOnThisOS else { return false }
        switch frame.phase {
        case .began:
            if let activeFrame {
                guard post(activeFrame.cancellation, at: position) else { return false }
                self.activeFrame = nil
            }
        case .changed, .ended, .cancelled:
            guard activeFrame?.axis == frame.axis else { return false }
        }
        guard post(frame, at: position) else { return false }
        switch frame.phase {
        case .began, .changed:
            activeFrame = frame
        case .ended, .cancelled:
            activeFrame = nil
        }
        return true
    }

    func cancel(at position: CGPoint) {
        guard let frame = activeFrame else { return }
        _ = post(frame.cancellation, at: position)
        activeFrame = nil
    }

    private func post(_ frame: DesktopGestureFrame, at position: CGPoint) -> Bool {
        guard let events = frame.makeEvents(at: position) else { return false }
        eventPoster(events.dock)
        eventPoster(events.marker)
        return true
    }
}
