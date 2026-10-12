import Foundation

public actor DownloadSlots {
    private var active: Set<UUID> = []
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    public func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < 2 { active.insert(id); return }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        }, onCancel: { Task { await self.cancel(id) } })
        if Task.isCancelled { release(id); throw CancellationError() }
    }

    public func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiters.isEmpty {
            let (next, continuation) = waiters.removeFirst()
            active.insert(next); continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
}
