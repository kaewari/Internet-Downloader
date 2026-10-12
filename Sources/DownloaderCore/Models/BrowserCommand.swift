import Foundation

public struct BrowserTaskInfo: Codable, Sendable {
    public var sourceKind = "browser"
    public var transferMethod = "browser_download"
    public var mediaKind: String
    public var selectionProof = "pending"
    public var verification = "NOT VERIFIED"
    public var phase = "queued"
    public var errorCode: String?
    public var errorStage: String?
    public var sha256: String?
    public var validationScope: String?
    public var phaseLabel: String {
        switch phase {
        case "queued": return "Đang chờ"
        case "saving_browser": return "Đang lưu qua Chrome"
        case "needs_confirmation": return "Cần chọn file trong extension"
        case "importing": return "Đang nhập file"
        case "validating": return "Đang kiểm tra file"
        case "completed": return "Hoàn tất"
        default: return "Lỗi phiên trình duyệt"
        }
    }
}

// Locators and transfer capabilities are exchanged only in memory. This object
// is never serialized into task history.
public struct BrowserCommand: Codable, Sendable {
    public var sessionId: String?
    public var token: String?
    public var mediaKind: String?
    public var filename: String?
    public var expectedSize: Int64?
    public var expectedDuration: Double?
    public var offset: Int64?
    public var data: String?
    public var sha256: String?
    public var selectionProof: String?
    public var errorCode: String?
    public var sourcePath: String?
    public var downloadId: Int?
    public var downloadState: String?

    public init(sessionId: String? = nil, token: String? = nil, mediaKind: String? = nil,
                filename: String? = nil, expectedSize: Int64? = nil, expectedDuration: Double? = nil,
                offset: Int64? = nil, data: String? = nil, sha256: String? = nil,
                selectionProof: String? = nil, errorCode: String? = nil, sourcePath: String? = nil,
                downloadId: Int? = nil, downloadState: String? = nil) {
        self.sessionId = sessionId; self.token = token; self.mediaKind = mediaKind
        self.filename = filename; self.expectedSize = expectedSize; self.expectedDuration = expectedDuration
        self.offset = offset; self.data = data; self.sha256 = sha256; self.selectionProof = selectionProof
        self.errorCode = errorCode; self.sourcePath = sourcePath; self.downloadId = downloadId; self.downloadState = downloadState
    }
}
