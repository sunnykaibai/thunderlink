import Foundation

enum TransferEdge: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "左边"
        case .right: return "右边"
        }
    }
}

enum WireMessageType: String, Codable {
    case hello
    case helloAck
    case activate
    case key
    case mouseMove
    case mouseButton
    case scroll
    case release
    case ping
    case pong
    case error
}

struct WireMessage: Codable, Equatable {
    var type: WireMessageType
    var protocolVersion: Int? = nil
    var computerName: String? = nil
    var pairingCode: String? = nil
    var edge: TransferEdge? = nil
    var keyCode: UInt16? = nil
    var eventKind: String? = nil
    var flags: UInt64? = nil
    var deltaX: Double? = nil
    var deltaY: Double? = nil
    var button: Int? = nil
    var clickCount: Int? = nil
    var scrollX: Double? = nil
    var scrollY: Double? = nil
    var message: String? = nil
    var capabilities: [String]? = nil

    static func hello(name: String, code: String, edge: TransferEdge) -> WireMessage {
        WireMessage(
            type: .hello,
            protocolVersion: 1,
            computerName: name,
            pairingCode: code,
            edge: edge,
            capabilities: ["heartbeat-v1"]
        )
    }
}

enum WireCodec {
    static let maxFrameBytes = 16 * 1_024

    static func encode(_ message: WireMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        guard data.count <= maxFrameBytes else {
            throw WireCodecError.frameTooLarge(data.count)
        }
        data.append(0x0A)
        return data
    }

    static func decodeLines(from buffer: inout Data) throws -> [WireMessage] {
        var messages: [WireMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard line.count <= maxFrameBytes else {
                throw WireCodecError.frameTooLarge(line.count)
            }
            messages.append(try JSONDecoder().decode(WireMessage.self, from: Data(line)))
        }
        guard buffer.count <= maxFrameBytes else {
            throw WireCodecError.frameTooLarge(buffer.count)
        }
        return messages
    }
}

enum WireCodecError: LocalizedError, Equatable {
    case frameTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let bytes):
            return "消息帧超过 \(WireCodec.maxFrameBytes) 字节（收到 \(bytes) 字节）"
        }
    }
}
