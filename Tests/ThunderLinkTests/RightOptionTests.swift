import CoreGraphics
import Foundation
import Testing
@testable import ThunderLink

struct RightOptionTests {
    private typealias PostedKeyEvent = (
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    )

    private final class EventRecorder {
        var events: [PostedKeyEvent] = []
    }

    @Test func rightOptionFollowsControlAndDrainsAHeldPressAfterReturning() {
        var state = InputState()
        #expect(!state.capturesRightOption(61, controllingRemote: false))
        #expect(!state.capturesRightOption(58, controllingRemote: true))
        #expect(state.capturesRightOption(61, controllingRemote: true))
        state.observeKey(61, kind: "flags", flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
        state.suppressPressedInputUntilRelease()
        #expect(state.capturesRightOption(61, controllingRemote: false))
        state.observeKey(61, kind: "flags", flags: [])
        #expect(!state.capturesRightOption(61, controllingRemote: false))
    }

    @Test func rightOptionPressAndReleaseSurviveWireRoundTrip() throws {
        let recorder = EventRecorder()
        let injector = makeInjector(recorder: recorder)
        injector.activate(edge: .right)

        let rightOptionFlags = CGEventFlags(
            rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0040
        )
        let messages = [
            WireMessage(
                type: .key,
                keyCode: 61,
                eventKind: "flags",
                flags: rightOptionFlags.rawValue
            ),
            WireMessage(type: .key, keyCode: 61, eventKind: "flags", flags: 0)
        ]

        for message in messages {
            var buffer = try WireCodec.encode(message)
            let decoded = try WireCodec.decodeLines(from: &buffer)
            #expect(buffer.isEmpty)
            #expect(decoded == [message])
            decoded.forEach(injector.handle)
        }

        let rightOptionEvents = recorder.events.filter { $0.keyCode == 61 }
        #expect(rightOptionEvents.map(\.type) == [.flagsChanged, .flagsChanged])
        #expect(rightOptionEvents.map(\.flags) == [rightOptionFlags, []])
    }

    @Test func leftAndRightOptionKeepDistinctKeyCodes() {
        let recorder = EventRecorder()
        let injector = makeInjector(recorder: recorder)
        injector.activate(edge: .right)

        let leftOptionFlags = CGEventFlags(
            rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0020
        )
        let rightOptionFlags = CGEventFlags(
            rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0040
        )
        injector.handle(WireMessage(
            type: .key,
            keyCode: 58,
            eventKind: "flags",
            flags: leftOptionFlags.rawValue
        ))
        injector.handle(WireMessage(
            type: .key,
            keyCode: 61,
            eventKind: "flags",
            flags: rightOptionFlags.rawValue
        ))

        let optionEvents = recorder.events.filter { $0.type == .flagsChanged }
        #expect(optionEvents.map(\.keyCode) == [58, 61])
    }

    @Test func returningWhileRightOptionIsHeldReleasesItOnlyOnce() {
        let recorder = EventRecorder()
        let injector = makeInjector(recorder: recorder)
        injector.activate(edge: .right)

        let rightOptionFlags = CGEventFlags(
            rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0040
        )
        injector.handle(WireMessage(
            type: .key,
            keyCode: 61,
            eventKind: "flags",
            flags: rightOptionFlags.rawValue
        ))
        injector.releaseAll()
        injector.releaseAll()

        let rightOptionEvents = recorder.events.filter { $0.keyCode == 61 }
        #expect(rightOptionEvents.map(\.type) == [.flagsChanged, .flagsChanged])
        #expect(rightOptionEvents.map(\.flags) == [rightOptionFlags, []])
    }

    private func makeInjector(recorder: EventRecorder) -> InputInjector {
        InputInjector(
            eventPoster: { event in
                guard event.type == .flagsChanged else { return }
                recorder.events.append((
                    event.type,
                    event.getIntegerValueField(.keyboardEventKeycode),
                    event.flags
                ))
            },
            primaryBounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
    }
}
