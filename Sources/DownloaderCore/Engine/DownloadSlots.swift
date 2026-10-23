import Foundation

/// Giới hạn 2 tải đồng thời (slot dùng chung cho HTTP/HLS/browser).
public actor DownloadSlots {
    private var active: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    // cancel có thể đến trước khi waiter được append (race) — nhớ lại để
    // acquire check và throw ngay thay vì treo continuation vĩnh viễn.
    private var pendingCancel: Set<UUID> = []

    private func registerWaiter(_ id: UUID) async throws {
        // Kiểuu cục bộ: tránh lỗi type-checker của Swift khi suy luận kiểu
        // continuation trong closure bất đồng bộ (Void, Error).
        let waiterType: CheckedContinuation<Void, Error>.Type = CheckedContinuation<Void, Error>.self
        _ = waiterType
        return try await withCheckedThrowingContinuation { cont in
            if pendingCancel.remove(id) != nil {
                cont.resume(throwing: CancellationError())
            } else {
                waiters[id] = cont
            }
        }
    }

    public func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if pendingCancel.remove(id) != nil {
            throw CancellationError()
        }
        if active.count < 2 {
            active.insert(id)
            return
        }
        let waitOp = { try await self.registerWaiter(id) }
        try await withTaskCancellationHandler(operation: waitOp, onCancel: {
            Task { await self.cancel(id) }
        })
        if Task.isCancelled {
            release(id)
            throw CancellationError()
        }
    }

    public func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        // A-F17: wake waiter tới khi đủ 2 slot hoặc hết waiter (trước đây
        // `return` sau waiter đầu tiên → under-utilize khi capacity còn trống).
        while !waiters.isEmpty && active.count < 2 {
            guard let next = waiters.first?.key, let continuation = waiters.removeValue(forKey: next) else { break }
            if pendingCancel.remove(next) != nil {
                // Waiter kế tiếp đã bị cancel khi xếp hàng — bỏ, xét waiter sau.
                continuation.resume(throwing: CancellationError())
                continue
            }
            active.insert(next)
            continuation.resume()
        }
    }

    /// Ghi nhận yêu cầu huỷ.
    ///
    /// Chỉ ghi nhớ khi task thực sự đang chờ slot; nếu task đang chạy (đã giữ
    /// slot) thì huỷ ở đây không liên quan tới lần `acquire` sau — ghi vào
    /// `pendingCancel` sẽ làm lần acquire sau của **cùng task** (người dùng
    /// bấm "Tiếp tục" sau khi huỷ) bị từ chối ngay, dù nó hợp lệ.
    private func cancel(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
            return
        }
        if active.contains(id) {
            // Task đang giữ slot → huỷ sẽ được xử lý ở lớp trên (DownloadManager).
            return
        }
        pendingCancel.insert(id)
    }
}
