import Foundation

public struct IPCRequest: Codable, Sendable {
    public let action: String
    public let url: String?
    public let filename: String?
    public let referrer: String?
    public let cookies: String?
    public let userAgent: String?
    public let taskId: String?

    public init(
        action: String,
        url: String? = nil,
        filename: String? = nil,
        referrer: String? = nil,
        cookies: String? = nil,
        userAgent: String? = nil,
        taskId: String? = nil
    ) {
        self.action = action
        self.url = url
        self.filename = filename
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.taskId = taskId
    }
}

public struct IPCResponse: Codable, Sendable {
    public let success: Bool
    public let taskId: String?
    public let message: String?
    public let extra: [String: String]?

    public init(
        success: Bool,
        taskId: String? = nil,
        message: String? = nil,
        extra: [String: String]? = nil
    ) {
        self.success = success
        self.taskId = taskId
        self.message = message
        self.extra = extra
    }
}
