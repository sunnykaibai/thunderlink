import CoreGraphics
import Testing
@testable import ThunderLink

struct InputInjectorTests {
    @Test func modifierFlagsAreReleasedWithoutPostingToTheRealEventTap() {
        var postedEvents: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)] = []
        let injector = InputInjector(
            eventPoster: {
                postedEvents.append((
                    $0.type,
                    $0.getIntegerValueField(.keyboardEventKeycode),
                    $0.flags
                ))
            },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )

        injector.activate(edge: .right)
        injector.handle(WireMessage(
            type: .key,
            keyCode: 59,
            eventKind: "flags",
            flags: CGEventFlags.maskControl.rawValue
        ))
        injector.releaseAll()

        #expect(postedEvents.map { $0.type.rawValue } == [
            CGEventType.mouseMoved.rawValue,
            CGEventType.flagsChanged.rawValue,
            CGEventType.flagsChanged.rawValue
        ])
        #expect(postedEvents.last?.keyCode == 59)
        #expect(postedEvents.last?.flags.isEmpty == true)
    }

    @Test func regularKeyReleaseUsesKeyUpWithClearedFlags() {
        var releasedEvent: (type: CGEventType, keyCode: Int64, flags: CGEventFlags)?
        let injector = InputInjector(
            eventPoster: {
                if $0.getIntegerValueField(.keyboardEventKeycode) == 12 {
                    releasedEvent = ($0.type, $0.getIntegerValueField(.keyboardEventKeycode), $0.flags)
                }
            },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        injector.activate(edge: .right)
        injector.handle(WireMessage(type: .key, keyCode: 12, eventKind: "down", flags: CGEventFlags.maskCommand.rawValue))
        releasedEvent = nil
        injector.releaseAll()

        #expect(releasedEvent?.type.rawValue == CGEventType.keyUp.rawValue)
        #expect(releasedEvent?.keyCode == 12)
        #expect(releasedEvent?.flags.isEmpty == true)
    }

    @Test func releaseClearsButtonsBeforeASecondRelease() {
        var postedTypes: [CGEventType] = []
        let injector = InputInjector(
            eventPoster: { postedTypes.append($0.type) },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )

        injector.activate(edge: .right)
        injector.handle(WireMessage(type: .mouseButton, eventKind: "down", button: 0))
        injector.releaseAll()
        injector.releaseAll()

        #expect(postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test func malformedEventsAreRejectedAndHugeScrollValuesAreClamped() {
        var postedTypes: [CGEventType] = []
        let injector = InputInjector(
            eventPoster: { postedTypes.append($0.type) },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        injector.activate(edge: .right)
        injector.handle(WireMessage(type: .mouseButton, eventKind: "sideways", button: 0))
        injector.handle(WireMessage(type: .mouseButton, eventKind: "down", button: 10_000))
        injector.handle(WireMessage(type: .key, keyCode: 12, eventKind: "repeat"))
        injector.handle(WireMessage(type: .key, keyCode: 10_000, eventKind: "down"))
        injector.handle(WireMessage(type: .scroll, scrollX: 1e300, scrollY: -1e300))
        injector.handle(WireMessage(type: .scroll, scrollX: .infinity, scrollY: 1))

        #expect(postedTypes == [.mouseMoved, .scrollWheel])
    }

    @Test func rightButtonDragKeepsItsButtonAndDoubleClickState() {
        var postedEvents: [(CGEventType, Int64, Int64)] = []
        let injector = InputInjector(
            eventPoster: {
                postedEvents.append((
                    $0.type,
                    $0.getIntegerValueField(.mouseEventButtonNumber),
                    $0.getIntegerValueField(.mouseEventClickState)
                ))
            },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        injector.activate(edge: .right)
        injector.handle(WireMessage(
            type: .mouseButton,
            eventKind: "down",
            button: 1,
            clickCount: 2
        ))
        injector.handle(WireMessage(type: .mouseMove, deltaX: 5, deltaY: 0))

        #expect(postedEvents.map { $0.0 } == [.mouseMoved, .rightMouseDown, .rightMouseDragged])
        #expect(postedEvents[1].1 == 1)
        #expect(postedEvents[1].2 == 2)
        #expect(postedEvents[2].1 == 1)
    }
}
