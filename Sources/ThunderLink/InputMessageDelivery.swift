import Foundation

/// Serializes injection on the main queue without scheduling one task per event.
/// Disconnection replaces pending input with a release before a new session starts.
final class InputMessageDelivery {
    private let mailbox: BoundedMessageMailbox
    private let queue: DispatchQueue
    private let onMessage: (WireMessage) -> Void
    private let onOverflow: () -> Void
    private let stateLock = NSLock()
    private var generation: UInt64 = 0

    init(capacity: Int = 256, queue: DispatchQueue = .main,
         onMessage: @escaping (WireMessage) -> Void, onOverflow: @escaping () -> Void) {
        mailbox = BoundedMessageMailbox(capacity: capacity)
        self.queue = queue
        self.onMessage = onMessage
        self.onOverflow = onOverflow
    }

    func submit(_ message: WireMessage) {
        stateLock.lock()
        let result = mailbox.offer(message)
        stateLock.unlock()
        handle(result)
    }

    private func handle(_ result: BoundedMessageMailbox.OfferResult) {
        switch result {
        case .accepted(let scheduleDrain):
            if scheduleDrain { schedule() }
        case .criticalOverflow:
            // A previously scheduled drain owns the cleanup; do not enqueue a task
            // for each subsequent input event while the consumer is blocked.
            onOverflow()
        case .droppedDisposable, .closed:
            break
        }
    }

    func reset() {
        stateLock.lock()
        generation &+= 1
        mailbox.reset()
        let result = mailbox.offer(WireMessage(type: .release))
        stateLock.unlock()
        handle(result)
    }

    private func schedule() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let generation = self.generation
            let batch = self.mailbox.drain()
            self.stateLock.unlock()
            for message in batch {
                self.stateLock.lock()
                let isCurrent = generation == self.generation
                self.stateLock.unlock()
                // A reset also invalidates values already taken out of the mailbox.
                // The currently executing event may finish; subsequent old input cannot run.
                guard isCurrent else { return }
                self.onMessage(message)
            }
        }
    }
}
