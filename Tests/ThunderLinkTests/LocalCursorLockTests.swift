import CoreGraphics
import Testing
@testable import ThunderLink

struct LocalCursorLockTests {
    @Test func backgroundMovementAlwaysReturnsToSameAnchor() {
        var positions: [CGPoint] = []
        let lock = LocalCursorLock { positions.append($0); return .success }
        #expect(lock.acquire(at: CGPoint(x: 1439, y: 420), in: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        for _ in 0..<1_000 { #expect(lock.hold()) }
        #expect(positions.count == 1_001)
        #expect(positions.allSatisfy { $0 == CGPoint(x: 1435, y: 420) })
        // No application activation or foreground-only association is required.
    }

    @Test func initialWarpFailureCannotAcquireLock() {
        let lock = LocalCursorLock { _ in .failure }
        #expect(!lock.acquire(at: .zero, in: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(lock.anchor == nil)
        #expect(!lock.hold())
    }

    @Test func warpFailureDuringTransferIsReported() {
        var succeeds = true
        let lock = LocalCursorLock { _ in succeeds ? .success : .failure }
        #expect(lock.acquire(at: .zero, in: CGRect(x: 0, y: 0, width: 100, height: 100)))
        succeeds = false
        #expect(!lock.hold())
    }

    @Test func releaseStopsWarpingAndNextTransferUsesNewAnchor() {
        var positions: [CGPoint] = []
        let lock = LocalCursorLock { positions.append($0); return .success }
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(lock.acquire(at: CGPoint(x: 99, y: 30), in: bounds))
        lock.release()
        #expect(!lock.hold())
        #expect(positions.count == 1)
        #expect(lock.acquire(at: CGPoint(x: 0, y: 60), in: bounds))
        #expect(lock.hold())
        #expect(positions.suffix(2).allSatisfy { $0 == CGPoint(x: 4, y: 60) })
    }

    @Test func secondaryDisplayWithNegativeOriginStaysInsideItsBounds() {
        let lock = LocalCursorLock { _ in .success }
        let bounds = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(lock.acquire(at: CGPoint(x: -1920, y: -200), in: bounds))
        #expect(lock.anchor == CGPoint(x: -1916, y: -196))
    }

    @Test func invalidDisplayDoesNotWarp() {
        var called = false
        let lock = LocalCursorLock { _ in called = true; return .success }
        #expect(!lock.acquire(at: .zero, in: .zero))
        #expect(!called)
    }
}
