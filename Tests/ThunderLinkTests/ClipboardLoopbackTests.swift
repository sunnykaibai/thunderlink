import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Network
import Testing
@testable import ThunderLink

struct ClipboardLoopbackTests {
    @Test @MainActor
    func authenticatedTCPConnectionSynchronizesPNGAndTextInBothDirections() async throws {
        let sourceBoard = namedPasteboard("source")
        let destinationBoard = namedPasteboard("destination")
        defer {
            sourceBoard.clearContents()
            destinationBoard.clearContents()
            sourceBoard.releaseGlobally()
            destinationBoard.releaseGlobally()
        }

        let sourceClipboard = ClipboardSync(pasteboard: sourceBoard)
        let destinationClipboard = ClipboardSync(pasteboard: destinationBoard)
        let remotePaste = RemotePaste()
        let receiver = ReceiverService(
            port: .any,
            authenticationTimeout: 2,
            bridgeValidator: { $0.usesThunderboltBridge() },
            transportFactory: { connection, queue in
                LoopbackBridgeTransport(
                    FramedConnection(connection: connection, queue: queue)
                )
            }
        )
        let client = ControllerClient(connectionTimeout: 3)

        var receiverPort: NWEndpoint.Port?
        var clientSession: UUID?
        var receiverSession: UUID?
        var ordinaryMessageArrived = false
        var expectedPastePNG: Data?
        var pasteArrivedAfterClipboard = false
        var pasteTimedOut = false

        receiver.onListening = { port in
            Task { @MainActor in receiverPort = port }
        }
        receiver.onClipboardSession = { session in
            Task { @MainActor in
                receiverSession = session
                if let session {
                    destinationClipboard.start { payload in
                        receiver.sendClipboard(payload, session: session)
                    }
                } else {
                    destinationClipboard.stop()
                }
            }
        }
        destinationClipboard.onRemoteResolved = { revision in
            guard let session = receiverSession else { return }
            receiver.acknowledgeClipboard(revision, session: session)
        }
        receiver.onClipboardReceived = { session, payload in
            Task { @MainActor in
                guard receiverSession == session else { return }
                destinationClipboard.receive(payload)
            }
        }
        receiver.onAuthenticatedMessage = { message in
            Task { @MainActor in
                if message.type == .mouseMove {
                    ordinaryMessageArrived = true
                }
                if message.type == .key, message.eventKind == "down",
                   message.keyCode == UInt16(kVK_ANSI_V) {
                    pasteArrivedAfterClipboard = destinationBoard.data(forType: .png)
                        == expectedPastePNG
                }
            }
        }

        client.onClipboardSession = { session in
            Task { @MainActor in
                clientSession = session
                if let session {
                    sourceClipboard.start { payload in
                        client.sendClipboard(payload, session: session)
                    }
                } else {
                    sourceClipboard.stop()
                }
            }
        }
        client.onClipboardReceived = { session, payload in
            Task { @MainActor in
                guard clientSession == session else { return }
                sourceClipboard.receive(payload)
            }
        }
        sourceClipboard.onRemoteResolved = { revision in
            guard let session = clientSession else { return }
            client.acknowledgeClipboard(revision, session: session)
        }
        client.onClipboardAcknowledged = { session, revision in
            Task { @MainActor in
                guard clientSession == session else { return }
                remotePaste.acknowledge(revision)
            }
        }
        remotePaste.send = { message in client.send(message) }
        remotePaste.onTimeout = { pasteTimedOut = true }

        try receiver.start(pairingCode: "123456")
        defer {
            sourceClipboard.stop()
            destinationClipboard.stop()
            client.disconnect()
            receiver.stop()
        }
        try await waitUntil(.listener) { receiverPort != nil }
        let port = try #require(receiverPort)

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let transport = LoopbackBridgeTransport(
            FramedConnection(
                connection: connection,
                queue: DispatchQueue(label: "com.sunny.thunderlink.tests.clipboard-client")
            )
        )
        client.connect(
            transport: transport,
            name: "loopback",
            code: "123456",
            edge: .right
        )
        try await waitUntil(.authentication) { clientSession != nil && receiverSession != nil }

        let png = try makeIncompressiblePNG()
        expectedPastePNG = png
        #expect(png.count > ClipboardChunk.dataBytes * 4)
        let imageItem = NSPasteboardItem()
        imageItem.setData(png, forType: .png)
        sourceBoard.clearContents()
        #expect(sourceBoard.writeObjects([imageItem]))
        let commandFlags = CGEventFlags.maskCommand.rawValue
        remotePaste.forward(
            WireMessage(
                type: .key,
                keyCode: UInt16(kVK_ANSI_V),
                eventKind: "down",
                flags: commandFlags
            ),
            prepare: sourceClipboard.prepareForPaste
        )
        remotePaste.forward(
            WireMessage(
                type: .key,
                keyCode: UInt16(kVK_ANSI_V),
                eventKind: "up",
                flags: commandFlags
            ),
            prepare: sourceClipboard.prepareForPaste
        )

        // Ordinary authenticated traffic remains deliverable while Command-V
        // waits for a multi-frame clipboard image to be applied and acknowledged.
        client.send(WireMessage(type: .mouseMove, deltaX: 1, deltaY: -1))
        try await waitUntil(.forwardPaste) {
            ordinaryMessageArrived && pasteArrivedAfterClipboard
        }
        #expect(!pasteTimedOut)
        #expect(destinationBoard.data(forType: .png) == png)
        #expect(NSImage(data: try #require(destinationBoard.data(forType: .png))) != nil)

        let text = "ThunderLink 双向剪贴板 · \(UUID().uuidString)"
        destinationBoard.clearContents()
        #expect(destinationBoard.setString(text, forType: .string))
        destinationClipboard.poll()
        try await waitUntil(.reverseText) { sourceBoard.string(forType: .string) == text }
        #expect(destinationBoard.string(forType: .string) == text)

        let reversePNG = try makeIncompressiblePNG(seed: 0xC11F_B04D)
        let reverseItem = NSPasteboardItem()
        reverseItem.setData(reversePNG, forType: .png)
        destinationBoard.clearContents()
        #expect(destinationBoard.writeObjects([reverseItem]))
        destinationClipboard.poll()
        try await waitUntil(.reversePNG) { sourceBoard.data(forType: .png) == reversePNG }
    }

    @MainActor
    private func waitUntil(
        _ failure: LoopbackError,
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { throw failure }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func namedPasteboard(_ suffix: String) -> NSPasteboard {
        let name = NSPasteboard.Name(
            "com.sunny.thunderlink.tests.clipboard-loopback.\(suffix).\(UUID().uuidString)"
        )
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        return pasteboard
    }

    private func makeIncompressiblePNG(seed: UInt32 = 0x51A7_EC0D) throws -> Data {
        let width = 320
        let height = 240
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        let bytes = try #require(representation.bitmapData)
        var state = seed
        for index in 0..<(width * height * 4) {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
        return try #require(representation.representation(using: .png, properties: [:]))
    }

    private enum LoopbackError: Error {
        case listener
        case authentication
        case forwardPaste
        case reverseText
        case reversePNG
    }
}

private final class LoopbackBridgeTransport: ConnectionTransport {
    private let base: FramedConnection

    init(_ base: FramedConnection) {
        self.base = base
    }

    var onMessage: ((WireMessage) -> Void)? {
        get { base.onMessage }
        set { base.onMessage = newValue }
    }

    var onState: ((NWConnection.State) -> Void)? {
        get { base.onState }
        set { base.onState = newValue }
    }

    var onInvalidFrame: ((Error) -> Void)? {
        get { base.onInvalidFrame }
        set { base.onInvalidFrame = newValue }
    }

    var onTransportError: ((Error) -> Void)? {
        get { base.onTransportError }
        set { base.onTransportError = newValue }
    }

    func start() { base.start() }
    func send(_ message: WireMessage) { base.send(message) }
    func sendClipboard(_ payload: ClipboardPayload) { base.sendClipboard(payload) }
    func sendThenClose(
        _ message: WireMessage,
        deadline: TimeInterval,
        completion: @escaping () -> Void
    ) {
        base.sendThenClose(message, deadline: deadline, completion: completion)
    }
    func cancel() { base.cancel() }
    func usesThunderboltBridge() -> Bool { true }
}
