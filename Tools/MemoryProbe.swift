import Darwin
import Foundation

/// Build with WireMessage.swift and OutboundMessageQueue.swift. This probe does
/// not start the app, open sockets, or post any keyboard or mouse events.
@main
struct MemoryProbe {
    static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Int64(usage.ru_maxrss)
    }

    static func main() throws {
        let mailbox = BoundedMessageMailbox(capacity: 256)
        var drainReservations = 0
        var overflows = 0
        var maxCount = 0
        var samples: [[String: Int64]] = []
        let start = Date()
        // Deliberately never drain: a stopped consumer must not accumulate either
        // unbounded messages or a Dispatch closure for each offered event.
        for index in 1...1_000_000 {
            let result = mailbox.offer(WireMessage(type: .key, keyCode: 1, eventKind: "down"))
            switch result {
            case .accepted(let scheduleDrain):
                if scheduleDrain { drainReservations += 1 }
            case .criticalOverflow: overflows += 1
            case .droppedDisposable, .closed: break
            }
            maxCount = max(maxCount, mailbox.count)
            if index == 100_000 || index == 1_000_000 {
                samples.append(["events": Int64(index), "peak_rss_bytes": peakResidentBytes()])
            }
        }
        precondition(maxCount == 256 && drainReservations == 1 && overflows == 1)
        let additionalMemory = samples[1]["peak_rss_bytes"]! - samples[0]["peak_rss_bytes"]!
        precondition(additionalMemory < 8 * 1_024 * 1_024)
        let output: [String: Any] = [
            "offered_events": 1_000_000,
            "queue_peak_messages": maxCount,
            "drain_reservations": drainReservations,
            "overflow_notifications": overflows,
            "samples": samples,
            "additional_peak_rss_bytes_after_warmup": additionalMemory,
            "wallclock_seconds": Date().timeIntervalSince(start)
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
