import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import ThunderLink

@MainActor
struct RemotePasteTests {
    private let paste = WireMessage(type: .key, keyCode: UInt16(kVK_ANSI_V), eventKind: "down", flags: CGEventFlags.maskCommand.rawValue)
    private let up = WireMessage(type: .key, keyCode: UInt16(kVK_ANSI_V), eventKind: "up", flags: CGEventFlags.maskCommand.rawValue)

    @Test func waitsForClipboardWriteBeforeForwardingPasteAndKeyUp() {
        let gate = RemotePaste()
        let origin = UUID()
        let revision = ClipboardRevision(counter: 2, origin: origin)
        var sent: [WireMessage] = []
        gate.send = { sent.append($0) }
        gate.forward(paste) { ready in ready(revision) }
        gate.forward(up) { _ in Issue.record("A key-up cannot start a second paste.") }
        gate.acknowledge(ClipboardRevision(counter: 1, origin: origin))
        #expect(sent.isEmpty)
        gate.acknowledge(revision)
        #expect(sent == [paste, up])
    }

    @Test func acknowledgementMayArriveBeforeConversionCallback() {
        let gate = RemotePaste()
        let revision = ClipboardRevision(counter: 1, origin: UUID())
        var sent: [WireMessage] = []
        gate.send = { sent.append($0) }
        var prepared: ((ClipboardRevision?) -> Void)?
        gate.forward(paste) { prepared = $0 }
        gate.acknowledge(revision)
        #expect(sent.isEmpty)
        prepared?(revision)
        #expect(sent == [paste])
    }

    @Test func returningMouseCancelsPendingPasteAndIgnoresLateCompletion() {
        let gate = RemotePaste()
        let release = WireMessage(type: .release)
        var sent: [WireMessage] = []
        gate.send = { sent.append($0) }
        var prepared: ((ClipboardRevision?) -> Void)?
        gate.forward(paste) { prepared = $0 }
        gate.forward(release) { _ in }
        prepared?(nil)
        #expect(sent == [release])
    }
}
