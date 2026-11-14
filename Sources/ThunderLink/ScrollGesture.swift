import AppKit
import CoreGraphics

enum ScrollGesture {
    static func message(from event: CGEvent) -> WireMessage {
        let appEvent = NSEvent(cgEvent: event)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let preciseX: Double? = continuous
            ? (appEvent.map { Double($0.scrollingDeltaX) }
                ?? event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * 10)
            : nil
        let preciseY: Double? = continuous
            ? (appEvent.map { Double($0.scrollingDeltaY) }
                ?? event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 10)
            : nil
        return WireMessage(
            type: .scroll,
            scrollX: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
            scrollY: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
            scrollPreciseX: preciseX,
            scrollPreciseY: preciseY,
            scrollPhase: phase(event, field: .scrollWheelEventScrollPhase),
            scrollMomentumPhase: phase(event, field: .scrollWheelEventMomentumPhase),
            scrollContinuous: continuous ? true : nil
        )
    }

    private static func phase(_ event: CGEvent, field: CGEventField) -> UInt64? {
        let value = event.getIntegerValueField(field)
        return value > 0 ? UInt64(value) : nil
    }
}
