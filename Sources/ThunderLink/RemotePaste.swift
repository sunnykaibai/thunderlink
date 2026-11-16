import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Keep a forwarded paste and the input following it in order while its
/// clipboard item is being converted, sent and written on the other Mac.
@MainActor
final class RemotePaste {
    var send: (WireMessage) -> Void = { _ in }
    var onTimeout: () -> Void = {}

    private var queue = OutboundMessageQueue()
    private var awaiting: ClipboardRevision?
    private var lastAcknowledged: ClipboardRevision?
    private var ticket: UUID?
    private var timeout: DispatchWorkItem?
    private var suppressVUp = false

    func forward(_ message: WireMessage, prepare: (@escaping (ClipboardRevision?) -> Void) -> Void) {
        if message.type == .release || message.type == .activate {
            cancelPending()
            send(message)
            return
        }
        if suppressVUp, isV(message) {
            if message.eventKind == "up" { suppressVUp = false }
            return
        }
        if ticket != nil {
            if queue.enqueue(message) == .criticalOverflow {
                finish(deliverPaste: false)
                forward(message, prepare: prepare)
            }
            return
        }
        guard Self.isPaste(message) else {
            send(message)
            return
        }
        let id = UUID()
        ticket = id
        queue.enqueue(message)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ticket == id else { return }
            self.finish(deliverPaste: false)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        prepare { [weak self] revision in
            guard let self, self.ticket == id else { return }
            guard let revision else { self.finish(deliverPaste: true); return }
            self.awaiting = revision
            if let ack = self.lastAcknowledged, ack >= revision {
                self.finish(deliverPaste: true)
            }
        }
    }

    func acknowledge(_ revision: ClipboardRevision) {
        if let lastAcknowledged, revision <= lastAcknowledged { return }
        lastAcknowledged = revision
        if let awaiting, revision >= awaiting { finish(deliverPaste: true) }
    }

    func resetSession() {
        cancelPending()
        lastAcknowledged = nil
    }

    func cancelPending() {
        timeout?.cancel()
        timeout = nil
        queue = OutboundMessageQueue()
        awaiting = nil
        ticket = nil
        suppressVUp = false
    }

    private func finish(deliverPaste: Bool) {
        let buffered = queue.messages
        cancelPending()
        for item in buffered {
            if !deliverPaste && Self.isPaste(item) { suppressVUp = true }
            if suppressVUp && isV(item) {
                if item.eventKind == "up" { suppressVUp = false }
            } else {
                send(item)
            }
        }
        if !deliverPaste { onTimeout() }
    }

    private static func isPaste(_ message: WireMessage) -> Bool {
        guard message.type == .key, message.eventKind == "down",
              message.keyCode == UInt16(kVK_ANSI_V) else { return false }
        let flags = CGEventFlags(rawValue: message.flags ?? 0)
        return flags.contains(.maskCommand) && !flags.contains(.maskControl)
    }

    private func isV(_ message: WireMessage) -> Bool {
        message.type == .key && message.keyCode == UInt16(kVK_ANSI_V)
    }
}
