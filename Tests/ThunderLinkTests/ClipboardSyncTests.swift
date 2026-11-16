import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ThunderLink

struct ClipboardSyncTests {
    @Test @MainActor func startUsesTheCurrentClipboardAsBaseline() {
        let board = namedBoard()
        setText("before", on: board)
        var sent: [ClipboardPayload] = []
        let sync = makeSync(board: board, origin: uuid(1))
        sync.start { sent.append($0) }
        sync.poll()
        #expect(sent.isEmpty)

        setText("after", on: board)
        sync.poll()
        #expect(sent.count == 1)
        #expect(sent[0].format == .text)
        #expect(String(data: sent[0].data, encoding: .utf8) == "after")
        sync.stop()
    }

    @Test @MainActor func textMovesBothDirectionsWithoutEcho() throws {
        let leftBoard = namedBoard()
        let rightBoard = namedBoard()
        let left = makeSync(board: leftBoard, origin: uuid(1))
        let right = makeSync(board: rightBoard, origin: uuid(2))
        var leftToRight: [ClipboardPayload] = []
        var rightToLeft: [ClipboardPayload] = []
        left.start { leftToRight.append($0) }
        right.start { rightToLeft.append($0) }

        setText("left", on: leftBoard)
        left.poll()
        right.receive(try #require(leftToRight.last))
        right.poll()
        #expect(rightBoard.string(forType: .string) == "left")
        #expect(rightToLeft.isEmpty)

        setText("right", on: rightBoard)
        right.poll()
        left.receive(try #require(rightToLeft.last))
        left.poll()
        #expect(leftBoard.string(forType: .string) == "right")
        #expect(leftToRight.count == 1)
        left.stop()
        right.stop()
    }

    @Test @MainActor func pngIsPreferredOverTextAndReceivedAsAnImage() throws {
        let sourceBoard = namedBoard()
        let targetBoard = namedBoard()
        let source = makeSync(board: sourceBoard, origin: uuid(1))
        let target = makeSync(board: targetBoard, origin: uuid(2))
        var payloads: [ClipboardPayload] = []
        source.start { payloads.append($0) }
        target.start { _ in }

        let png = try #require(imageData(type: .png))
        let item = NSPasteboardItem()
        item.setString("ignored", forType: .string)
        item.setData(png, forType: .png)
        sourceBoard.clearContents()
        sourceBoard.writeObjects([item])
        source.poll()
        let payload = try #require(payloads.last)
        #expect(payload.format == .png)
        #expect(payload.data == png)

        target.receive(payload)
        #expect(targetBoard.data(forType: .png) == png)
        #expect(targetBoard.string(forType: .string) == nil)
        source.stop()
        target.stop()
    }

    @Test @MainActor func tiffScreenshotConvertsToPNGOffThePasteboard() async throws {
        let board = namedBoard()
        let sync = makeSync(board: board, origin: uuid(1))
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }
        board.clearContents()
        board.setData(try #require(imageData(type: .tiff)), forType: .tiff)
        sync.poll()

        for _ in 0..<100 where payloads.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let payload = try #require(payloads.last)
        #expect(payload.format == .png)
        #expect(CGImageSourceCreateWithData(payload.data as CFData, nil) != nil)
        sync.stop()
    }

    @Test @MainActor func aNewerCopyMakesAnOlderTIFFConversionStale() async throws {
        let board = namedBoard()
        let conversionQueue = DispatchQueue(label: "clipboard-test-blocked")
        conversionQueue.suspend()
        let sync = ClipboardSync(
            pasteboard: board,
            origin: uuid(1),
            conversionQueue: conversionQueue,
            schedulesTimer: false
        )
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }
        board.clearContents()
        board.setData(try #require(imageData(type: .tiff)), forType: .tiff)
        sync.poll()
        setText("newer", on: board)
        sync.poll()
        conversionQueue.resume()
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let payload = try #require(payloads.last)
        #expect(payloads.count == 1)
        #expect(String(data: payload.data, encoding: .utf8) == "newer")
        sync.stop()
    }

    @Test @MainActor func rapidTIFFCopiesKeepOnlyTheNewestPendingConversion() async throws {
        let board = namedBoard()
        let conversionQueue = DispatchQueue(label: "clipboard-test-latest")
        conversionQueue.suspend()
        let sync = ClipboardSync(
            pasteboard: board,
            origin: uuid(1),
            conversionQueue: conversionQueue,
            schedulesTimer: false
        )
        let tiff = try #require(imageData(type: .tiff))
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }
        for _ in 0..<3 {
            board.clearContents()
            board.setData(tiff, forType: .tiff)
            sync.poll()
        }
        conversionQueue.resume()
        for _ in 0..<100 where payloads.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let payload = try #require(payloads.last)
        #expect(payloads.count == 1)
        #expect(payload.revision.counter == 3)
        sync.stop()
    }

    @Test @MainActor func simultaneousCopiesConvergeByRevisionOrder() throws {
        let leftBoard = namedBoard()
        let rightBoard = namedBoard()
        let left = makeSync(board: leftBoard, origin: uuid(1))
        let right = makeSync(board: rightBoard, origin: uuid(2))
        var fromLeft: [ClipboardPayload] = []
        var fromRight: [ClipboardPayload] = []
        left.start { fromLeft.append($0) }
        right.start { fromRight.append($0) }
        setText("left", on: leftBoard)
        setText("right", on: rightBoard)
        left.poll()
        right.poll()
        let leftPayload = try #require(fromLeft.last)
        let rightPayload = try #require(fromRight.last)

        left.receive(rightPayload)
        right.receive(leftPayload)
        let winning = leftPayload.revision < rightPayload.revision ? rightPayload : leftPayload
        let expected = String(data: winning.data, encoding: .utf8)
        #expect(leftBoard.string(forType: .string) == expected)
        #expect(rightBoard.string(forType: .string) == expected)
        left.stop()
        right.stop()
    }

    @Test @MainActor func transientAndFileClipboardItemsStayLocal() {
        let board = namedBoard()
        let sync = makeSync(board: board, origin: uuid(1))
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }

        for excluded in [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            .fileURL
        ] {
            let item = NSPasteboardItem()
            item.setString("private", forType: .string)
            item.setString("marker", forType: excluded)
            board.clearContents()
            board.writeObjects([item])
            sync.poll()
        }
        #expect(payloads.isEmpty)
        sync.stop()
    }

    @Test @MainActor func invalidRemoteDataDoesNotReplaceClipboard() {
        let board = namedBoard()
        setText("safe", on: board)
        let sync = makeSync(board: board, origin: uuid(1))
        sync.start { _ in }
        sync.receive(ClipboardPayload(
            revision: ClipboardRevision(counter: 1, origin: uuid(2)),
            format: .text,
            data: Data([0xff])
        ))
        #expect(board.string(forType: .string) == "safe")
        sync.stop()
    }

    @Test @MainActor func prepareForPasteReturnsTheNewLocalRevision() {
        let board = namedBoard()
        let sync = makeSync(board: board, origin: uuid(1))
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }
        setText("paste now", on: board)
        var prepared: ClipboardRevision?
        sync.prepareForPaste { prepared = $0 }
        #expect(prepared == payloads.last?.revision)
        sync.stop()
    }

    @Test @MainActor func prepareForPasteCompletesImmediatelyWithoutANewLocalCopy() {
        let board = namedBoard()
        setText("baseline", on: board)
        let sync = makeSync(board: board, origin: uuid(1))
        sync.start { _ in }
        var called = false
        var revision: ClipboardRevision?
        sync.prepareForPaste {
            called = true
            revision = $0
        }
        #expect(called)
        #expect(revision == nil)
        sync.stop()
    }

    @Test @MainActor func prepareForPasteWaitsForTIFFConversion() async throws {
        let board = namedBoard()
        let conversionQueue = DispatchQueue(label: "clipboard-test-prepare")
        conversionQueue.suspend()
        let sync = ClipboardSync(
            pasteboard: board,
            origin: uuid(1),
            conversionQueue: conversionQueue,
            schedulesTimer: false
        )
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }
        board.clearContents()
        board.setData(try #require(imageData(type: .tiff)), forType: .tiff)
        var called = false
        var prepared: ClipboardRevision?
        sync.prepareForPaste {
            called = true
            prepared = $0
        }
        #expect(!called)
        conversionQueue.resume()
        for _ in 0..<100 where !called {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(called)
        #expect(prepared == payloads.last?.revision)
        sync.stop()
    }

    @Test @MainActor func stopReleasesAPendingPastePreparation() throws {
        let board = namedBoard()
        let conversionQueue = DispatchQueue(label: "clipboard-test-stop")
        conversionQueue.suspend()
        let sync = ClipboardSync(
            pasteboard: board,
            origin: uuid(1),
            conversionQueue: conversionQueue,
            schedulesTimer: false
        )
        sync.start { _ in }
        board.clearContents()
        board.setData(try #require(imageData(type: .tiff)), forType: .tiff)
        var called = false
        sync.prepareForPaste { revision in
            called = true
            #expect(revision == nil)
        }
        sync.stop()
        #expect(called)
        conversionQueue.resume()
    }

    @Test @MainActor func emptyTextIsASupportedClipboardChange() throws {
        let board = namedBoard()
        let sync = makeSync(board: board, origin: uuid(1))
        var payloads: [ClipboardPayload] = []
        sync.start { payloads.append($0) }
        setText("", on: board)
        sync.poll()
        let payload = try #require(payloads.last)
        #expect(payloads.count == 1)
        #expect(payload.format == .text)
        #expect(payload.data.isEmpty)
        sync.stop()
    }

    @Test @MainActor func receivingRemoteDataResolvesItsRevisionWithoutEcho() {
        let board = namedBoard()
        let sync = makeSync(board: board, origin: uuid(1))
        var sent: [ClipboardPayload] = []
        var resolved: [ClipboardRevision] = []
        sync.start { sent.append($0) }
        sync.onRemoteResolved = { resolved.append($0) }
        let revision = ClipboardRevision(counter: 7, origin: uuid(2))
        sync.receive(ClipboardPayload(
            revision: revision,
            format: .text,
            data: Data("remote".utf8)
        ))
        sync.poll()
        #expect(resolved == [revision])
        #expect(sent.isEmpty)
        #expect(board.string(forType: .string) == "remote")
        sync.stop()
    }

    @Test @MainActor func invalidRemoteDataIsNotAcknowledged() {
        let board = namedBoard()
        let sync = makeSync(board: board, origin: uuid(1))
        var resolved: [ClipboardRevision] = []
        sync.start { _ in }
        sync.onRemoteResolved = { resolved.append($0) }
        sync.receive(ClipboardPayload(
            revision: ClipboardRevision(counter: 1, origin: uuid(2)),
            format: .png,
            data: Data("not an image".utf8)
        ))
        #expect(resolved.isEmpty)
        sync.stop()
    }

    @MainActor private func makeSync(board: NSPasteboard, origin: UUID) -> ClipboardSync {
        ClipboardSync(
            pasteboard: board,
            origin: origin,
            conversionQueue: DispatchQueue(label: "clipboard-test-conversion"),
            schedulesTimer: false
        )
    }

    private func namedBoard() -> NSPasteboard {
        NSPasteboard(name: .init("com.sunny.thunderlink.tests.\(UUID().uuidString)"))
    }

    private func setText(_ text: String, on board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func uuid(_ suffix: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
    }

    private func imageData(type: NSPasteboard.PasteboardType) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        let identifier = type == .png ? UTType.png.identifier : UTType.tiff.identifier
        guard let destination = CGImageDestinationCreateWithData(
            output,
            identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
