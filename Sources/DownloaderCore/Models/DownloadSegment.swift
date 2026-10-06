import Foundation

public enum SegmentStatus: String, Codable, Sendable {
    case pending
    case downloading
    case paused
    case completed
    case failed
}

public struct DownloadSegment: Identifiable, Codable, Sendable {
    public let id: UUID
    public let taskId: UUID
    public let index: Int
    public let startByte: Int64
    public let endByte: Int64
    public var downloadedBytes: Int64
    public var status: SegmentStatus

    public var expectedBytes: Int64 {
        guard endByte >= startByte else { return 0 }
        return endByte - startByte + 1
    }

    public var currentByte: Int64 {
        startByte + downloadedBytes
    }

    public var progress: Double {
        guard expectedBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(expectedBytes)))
    }

    public func tempFile(in tempDir: URL) -> URL {
        tempDir.appendingPathComponent("segment_\(index).part")
    }

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        index: Int,
        startByte: Int64,
        endByte: Int64,
        downloadedBytes: Int64 = 0,
        status: SegmentStatus = .pending
    ) {
        self.id = id
        self.taskId = taskId
        self.index = index
        self.startByte = startByte
        self.endByte = endByte
        self.downloadedBytes = downloadedBytes
        self.status = status
    }
}
