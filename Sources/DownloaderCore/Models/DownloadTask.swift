import Foundation

public enum TaskStatus: String, Codable, Sendable {
    case pending
    case downloading
    case paused
    case assembling
    case completed
    case failed
    case needsConfirmation = "needs_confirmation"
}

public struct DownloadTask: Identifiable, Codable, Sendable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var destinationFolder: URL
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var status: TaskStatus
    public var speed: Double // Bytes per second
    public var etag: String?
    public var lastModified: String?
    public var acceptRanges: Bool
    public var segmentsCount: Int
    public var downloadedSegmentsCount: Int
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var referrer: String?
    public var userAgent: String?
    public var cookies: String?
    public var headers: [String: String]?
    public var browserInfo: BrowserTaskInfo?

    public var progress: Double {
        if totalBytes > 0 {
            return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
        }
        if segmentsCount > 0 && downloadedSegmentsCount > 0 {
            return min(1.0, max(0.0, Double(downloadedSegmentsCount) / Double(segmentsCount)))
        }
        return 0.0
    }

    public var finalFilePath: URL {
        destinationFolder.appendingPathComponent(filename)
    }

    public var tempDirectory: URL {
        destinationFolder.appendingPathComponent(".download_\(id.uuidString)")
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String = "",
        destinationFolder: URL,
        totalBytes: Int64 = -1,
        downloadedBytes: Int64 = 0,
        status: TaskStatus = .pending,
        speed: Double = 0.0,
        etag: String? = nil,
        lastModified: String? = nil,
        acceptRanges: Bool = false,
        segmentsCount: Int = 8,
        downloadedSegmentsCount: Int = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        referrer: String? = nil,
        userAgent: String? = nil,
        cookies: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename.isEmpty ? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent) : filename
        self.destinationFolder = destinationFolder
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.status = status
        self.speed = speed
        self.etag = etag
        self.lastModified = lastModified
        self.acceptRanges = acceptRanges
        self.segmentsCount = segmentsCount
        self.downloadedSegmentsCount = downloadedSegmentsCount
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.referrer = referrer
        self.userAgent = userAgent
        self.cookies = cookies
        self.headers = headers
    }
}
