import Foundation

/// Bounded FIFO that combines adjacent high-frequency pointer events while
/// preserving ordering around keyboard and button transitions.
struct OutboundMessageQueue {
    enum EnqueueResult: Equatable {
        case enqueued
        case coalesced
        case droppedDisposable
        case criticalOverflow
    }

    private(set) var messages: [WireMessage] = []
    let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = max(8, capacity)
    }

    var isEmpty: Bool { messages.isEmpty }
    var count: Int { messages.count }

    @discardableResult
    mutating func enqueue(_ message: WireMessage) -> EnqueueResult {
        if coalesceWithLast(message) { return .coalesced }

        if messages.count >= capacity {
            if let disposable = messages.firstIndex(where: { $0.type == .mouseMove || $0.type == .scroll }) {
                messages.remove(at: disposable)
            } else if message.type == .mouseMove || message.type == .scroll {
                return .droppedDisposable
            } else {
                return .criticalOverflow
            }
        }
        messages.append(message)
        return .enqueued
    }

    mutating func popFirst() -> WireMessage? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    private mutating func coalesceWithLast(_ message: WireMessage) -> Bool {
        guard !messages.isEmpty, messages[messages.count - 1].type == message.type else { return false }
        let index = messages.count - 1
        switch message.type {
        case .mouseMove:
            messages[index].deltaX = (messages[index].deltaX ?? 0) + (message.deltaX ?? 0)
            messages[index].deltaY = (messages[index].deltaY ?? 0) + (message.deltaY ?? 0)
            return true
        case .scroll:
            messages[index].scrollX = (messages[index].scrollX ?? 0) + (message.scrollX ?? 0)
            messages[index].scrollY = (messages[index].scrollY ?? 0) + (message.scrollY ?? 0)
            return true
        default:
            return false
        }
    }
}

/// A lock-protected, bounded handoff for `WireMessage` values.
///
/// Producers receive a `scheduleDrain` token only when they transition the
/// mailbox from idle to having a drain reserved. This keeps a burst of input
/// events from creating one Dispatch closure per event.
final class BoundedMessageMailbox: @unchecked Sendable {
    enum OfferResult {
        case accepted(scheduleDrain: Bool)
        case droppedDisposable
        case criticalOverflow
        case closed
    }

    private let lock = NSLock()
    private var queue: OutboundMessageQueue
    private var drainScheduled = false
    private var accepting = true

    init(capacity: Int = 256) {
        queue = OutboundMessageQueue(capacity: capacity)
    }

    var count: Int {
        lock.withLock { queue.count }
    }

    var isEmpty: Bool {
        lock.withLock { queue.isEmpty }
    }

    func offer(_ message: WireMessage) -> OfferResult {
        lock.withLock {
            guard accepting else { return .closed }
            switch queue.enqueue(message) {
            case .enqueued, .coalesced:
                let shouldSchedule = !drainScheduled
                drainScheduled = true
                return .accepted(scheduleDrain: shouldSchedule)
            case .droppedDisposable:
                return .droppedDisposable
            case .criticalOverflow:
                accepting = false
                return .criticalOverflow
            }
        }
    }

    /// Atomically takes the current batch and releases the drain reservation.
    /// Use this when one scheduled callback can consume the entire batch.
    func drain() -> [WireMessage] {
        lock.withLock {
            let messages = queue.messages
            queue = OutboundMessageQueue(capacity: queue.capacity)
            drainScheduled = false
            return messages
        }
    }

    /// Takes one item while retaining the drain reservation. If the mailbox is
    /// empty, it atomically becomes idle so the next producer schedules work.
    func nextOrBecomeIdle() -> WireMessage? {
        lock.withLock {
            guard let message = queue.popFirst() else {
                drainScheduled = false
                return nil
            }
            return message
        }
    }

    /// Removes buffered values without reopening an overflowed mailbox.
    func clear() {
        lock.withLock {
            queue = OutboundMessageQueue(capacity: queue.capacity)
        }
    }

    /// Removes buffered values and accepts new input again. An already-reserved
    /// drain remains reserved, preventing duplicate Dispatch closures during a
    /// disconnect/reset race.
    func reset() {
        lock.withLock {
            queue = OutboundMessageQueue(capacity: queue.capacity)
            accepting = true
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
