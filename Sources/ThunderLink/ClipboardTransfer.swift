import Foundation

struct ClipboardRevision: Codable, Equatable, Comparable {
    let counter: UInt64
    let origin: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.origin.uuidString < rhs.origin.uuidString
    }
}

enum ClipboardFormat: String, Codable, Equatable {
    case text
    case png
}

struct ClipboardPayload: Equatable {
    static let capability = "clipboard-v1"
    static let maxBytes = 32 * 1_024 * 1_024

    let revision: ClipboardRevision
    let format: ClipboardFormat
    let data: Data
}

struct ClipboardChunk: Codable, Equatable {
    /// 8 KiB becomes about 11 KiB after JSON base64 encoding, leaving ample
    /// room below WireCodec's 16 KiB frame limit for metadata.
    static let dataBytes = 8 * 1_024

    let revision: ClipboardRevision
    let format: ClipboardFormat
    let index: Int
    let count: Int
    let totalBytes: Int
    let data: Data
}

struct ClipboardSendState {
    let payload: ClipboardPayload
    private(set) var nextIndex = 0

    var hasRemainingChunks: Bool { nextIndex < chunkCount }

    private var chunkCount: Int {
        max(1, (payload.data.count + ClipboardChunk.dataBytes - 1) / ClipboardChunk.dataBytes)
    }

    mutating func nextMessage() -> WireMessage? {
        guard hasRemainingChunks else { return nil }
        let lowerBound = nextIndex * ClipboardChunk.dataBytes
        let upperBound = min(lowerBound + ClipboardChunk.dataBytes, payload.data.count)
        let bytes = payload.data.subdata(in: lowerBound..<upperBound)
        let chunk = ClipboardChunk(
            revision: payload.revision,
            format: payload.format,
            index: nextIndex,
            count: chunkCount,
            totalBytes: payload.data.count,
            data: bytes
        )
        nextIndex += 1
        return WireMessage(type: .clipboardChunk, clipboardChunk: chunk)
    }
}

struct ClipboardAssembler {
    private struct Transfer {
        let revision: ClipboardRevision
        let format: ClipboardFormat
        let count: Int
        let totalBytes: Int
        var nextIndex: Int
        var data: Data
    }

    private var transfer: Transfer?
    private var lastCompletedRevision: ClipboardRevision?

    mutating func receive(_ message: WireMessage) -> ClipboardPayload? {
        guard message.type == .clipboardChunk,
              let chunk = message.clipboardChunk,
              Self.isValid(chunk) else { return nil }

        if chunk.revision == lastCompletedRevision { return nil }
        if chunk.index == 0 {
            if let active = transfer {
                if active.revision > chunk.revision { return nil }
                if active.revision == chunk.revision {
                    guard active.format == chunk.format,
                          active.count == chunk.count,
                          active.totalBytes == chunk.totalBytes else { return nil }
                    // The transport is ordered. A repeated first frame belongs
                    // to the same transfer and must not discard later progress.
                    if active.nextIndex > 0 { return nil }
                }
            }
            transfer = Transfer(
                revision: chunk.revision,
                format: chunk.format,
                count: chunk.count,
                totalBytes: chunk.totalBytes,
                nextIndex: 0,
                data: Data(capacity: chunk.totalBytes)
            )
        }

        guard var active = transfer,
              active.revision == chunk.revision,
              active.format == chunk.format,
              active.count == chunk.count,
              active.totalBytes == chunk.totalBytes else { return nil }

        if chunk.index < active.nextIndex { return nil }
        guard chunk.index == active.nextIndex,
              active.data.count + chunk.data.count <= active.totalBytes else {
            transfer = nil
            return nil
        }

        // Drop the stored Data reference before appending so a large clipboard
        // transfer keeps one growing buffer instead of copying it for each chunk.
        transfer = nil
        active.data.append(chunk.data)
        active.nextIndex += 1
        transfer = active
        guard active.nextIndex == active.count else { return nil }
        transfer = nil
        guard active.data.count == active.totalBytes else { return nil }
        lastCompletedRevision = active.revision
        return ClipboardPayload(
            revision: active.revision,
            format: active.format,
            data: active.data
        )
    }

    private static func isValid(_ chunk: ClipboardChunk) -> Bool {
        guard (0...ClipboardPayload.maxBytes).contains(chunk.totalBytes),
              chunk.data.count <= ClipboardChunk.dataBytes,
              chunk.count == max(1, (chunk.totalBytes + ClipboardChunk.dataBytes - 1) / ClipboardChunk.dataBytes),
              (0..<chunk.count).contains(chunk.index) else { return false }
        let expectedBytes: Int
        if chunk.index == chunk.count - 1 {
            expectedBytes = chunk.totalBytes - chunk.index * ClipboardChunk.dataBytes
        } else {
            expectedBytes = ClipboardChunk.dataBytes
        }
        return chunk.data.count == expectedBytes
    }
}
