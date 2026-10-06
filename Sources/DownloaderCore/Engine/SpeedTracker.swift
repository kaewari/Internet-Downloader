import Foundation

public final class SpeedTracker: @unchecked Sendable {
    private struct Sample {
        let timestamp: Date
        let bytes: Int64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private let windowSeconds: TimeInterval

    public init(windowSeconds: TimeInterval = 2.0) {
        self.windowSeconds = windowSeconds
    }

    public func record(bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        samples.append(Sample(timestamp: now, bytes: bytes))
        prune(now: now)
    }

    private func prune(now: Date) {
        let threshold = now.addingTimeInterval(-windowSeconds)
        samples.removeAll { $0.timestamp < threshold }
    }

    public func currentSpeed() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        prune(now: now)

        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else {
            return 0.0
        }

        let timeDiff = last.timestamp.timeIntervalSince(first.timestamp)
        guard timeDiff > 0.05 else { return 0.0 }

        let totalBytes = samples.reduce(Int64(0)) { $0 + $1.bytes }
        return Double(totalBytes) / timeDiff
    }

    public func estimatedTimeRemaining(remainingBytes: Int64) -> TimeInterval? {
        let speed = currentSpeed()
        guard speed > 1024, remainingBytes > 0 else { return nil }
        return Double(remainingBytes) / speed
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
    }
}
