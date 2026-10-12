import Foundation

public struct DataURLResult: Sendable {
    public let data: Data
    public let mimeType: String
    public let suggestedExtension: String
}

public struct DataURLHandler: Sendable {
    public static func isDataURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "data" || url.absoluteString.hasPrefix("data:")
    }

    public static func parse(urlString: String) throws -> DataURLResult {
        guard urlString.hasPrefix("data:") else {
            throw URLError(.badURL)
        }

        let withoutScheme = String(urlString.dropFirst("data:".count))
        guard let commaIndex = withoutScheme.firstIndex(of: ",") else {
            throw URLError(.cannotDecodeContentData)
        }

        let metadata = String(withoutScheme[..<commaIndex])
        let payload = String(withoutScheme[withoutScheme.index(after: commaIndex)...])

        let isBase64 = metadata.contains(";base64")
        let mimeType: String
        if let firstPart = metadata.components(separatedBy: ";").first, !firstPart.isEmpty {
            mimeType = firstPart.trimmingCharacters(in: .whitespaces)
        } else {
            mimeType = "text/plain"
        }

        let data: Data
        if isBase64 {
            let cleanPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: cleanPayload, options: .ignoreUnknownCharacters) else {
                throw URLError(.cannotDecodeContentData)
            }
            data = decoded
        } else {
            let unescaped = payload.removingPercentEncoding ?? payload
            guard let decoded = unescaped.data(using: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            data = decoded
        }

        let ext = extensionForMimeType(mimeType)
        return DataURLResult(data: data, mimeType: mimeType, suggestedExtension: ext)
    }

    public static func extensionForMimeType(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "application/pdf": return "pdf"
        case "application/json": return "json"
        case "text/plain": return "txt"
        default: return "bin"
        }
    }
}
