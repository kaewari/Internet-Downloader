import Foundation

public struct FileTypeDetector: Sendable {

    /// Sanitize filename cho filesystem macOS: thay ký tự cấm / control chars,
    /// cap 255 byte, không để name rỗng.
    public static func sanitizeFilename(_ name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: ":|/\0")
        clean.unicodeScalars.removeAll { forbidden.contains($0) || $0.value < 32 }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "download" }
        if clean.count > 200 {
            let ext = (clean as NSString).pathExtension
            let base = (clean as NSString).deletingPathExtension
            clean = ext.isEmpty ? String(base.prefix(200)) : "\(String(base.prefix(190))).\(ext)"
        }
        return clean
    }

    /// Tên file không trùng: file(1).zip, file(2).zip — đúng hành vi IDM.
    public static func uniqueDestination(in folder: URL, filename: String, fileManager: FileManager = .default) -> URL {
        var candidate = folder.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        repeat {
            let name = ext.isEmpty ? "\(base)(\(counter))" : "\(base)(\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path) && counter < 1000
        return candidate
    }

    /// Checks if a string looks like an opaque identifier (UUID, hash, pure hex/digits) without an extension
    /// Các đuôi tệp mà bộ dò kiểu biết. Đuôi KHÔNG nằm trong tập này được
    /// coi là "không xác định" → có thể là đuôi sai do URL (ví dụ `format=h.264`)
    /// và sẽ được sửa lại theo magic byte sau khi tải.
    public static let knownExtensions: Set<String> = [
        // Media
        "mp4", "m4v", "m4a", "mov", "qt", "mkv", "webm", "avi", "flv", "ts", "m3u8", "mpd", "m4s",
        "mp3", "aac", "flac", "wav", "ogg", "opus", "wma",
        // Ảnh
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic", "avif", "tif", "tiff",
        // Tài liệu / gói
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "json", "xml",
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg", "pkg", "xar", "apk", "exe", "msi",
        "sqlite", "ttf", "otf", "woff", "woff2",
    ]

    public static func isOpaqueIdentifier(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return true }
        
        // If it already has a recognized non-numeric extension, it's not an opaque identifier
        let ext = (clean as NSString).pathExtension.lowercased()
        if !ext.isEmpty && ext.count <= 5 && !CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: ext)) {
            return false
        }

        // UUID format: 8-4-4-4-12 hex chars (e.g., 0051985e-a8eb-4dd4-b612-9aea80ca1b21)
        if clean.count == 36 && clean.split(separator: "-").count == 5 {
            let hexAndDash = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
            if CharacterSet(charactersIn: clean).isSubset(of: hexAndDash) {
                return true
            }
        }

        // MD5 (32), SHA1 (40), SHA256 (64) hex hash
        if [32, 40, 64].contains(clean.count) {
            let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if CharacterSet(charactersIn: clean).isSubset(of: hexChars) {
                return true
            }
        }

        // Numeric ID
        if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: clean)) {
            return true
        }

        return false
    }

    /// Extracts authoritative filename from URL query parameters (Azure Blob `rscd`, AWS S3 `response-content-disposition`, generic `filename`)
    public static func extractFilename(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else {
            return nil
        }

        // 1. Check Azure Blob Storage `rscd` (response-content-disposition) and S3 `response-content-disposition`
        for item in queryItems {
            let lowerName = item.name.lowercased()
            if lowerName == "rscd" || lowerName == "response-content-disposition" {
                if let val = item.value {
                    let unescaped = val.replacingOccurrences(of: "+", with: " ")
                    if let parsed = parseFilename(from: unescaped) {
                        return parsed
                    }
                }
            }
        }

        // 2. Check direct `filename`, `response-filename`, `download_filename`, `file` query params
        for item in queryItems {
            let lowerName = item.name.lowercased()
            if ["filename", "response-filename", "download_filename", "name"].contains(lowerName) {
                if let val = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                    let base = (val as NSString).lastPathComponent
                    let clean = base.trimmingCharacters(in: CharacterSet(charactersIn: "\"'/\\"))
                    let ext = (clean as NSString).pathExtension
                    if !ext.isEmpty && clean != "." && clean != ".." {
                        return clean
                    }
                }
            }
        }

        return nil
    }

    /// Parses Content-Disposition header conforming to RFC 6266 and RFC 5987
    public static func parseFilename(from contentDisposition: String) -> String? {
        let items = contentDisposition.replacingOccurrences(of: "+", with: " ")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var standardFilename: String?
        for item in items {
            let lower = item.lowercased()
            if lower.hasPrefix("filename*=") {
                let val = item.dropFirst("filename*=".count)
                if let utf8Part = val.split(separator: "''").last {
                    let decoded = String(utf8Part).removingPercentEncoding ?? String(utf8Part)
                    let base = (decoded as NSString).lastPathComponent
                    let clean = base.trimmingCharacters(in: CharacterSet(charactersIn: "\"'/\\"))
                    if !clean.isEmpty && clean != "." && clean != ".." { return clean }
                }
            } else if lower.hasPrefix("filename=") && standardFilename == nil {
                var val = String(item.dropFirst("filename=".count))
                if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                    val = String(val.dropFirst().dropLast())
                }
                let base = (val as NSString).lastPathComponent
                let clean = base.trimmingCharacters(in: CharacterSet(charactersIn: "\"'/\\"))
                if !clean.isEmpty && clean != "." && clean != ".." { standardFilename = clean }
            }
        }
        return standardFilename
    }

    /// Maps Content-Type (MIME) to standard file extension
    public static func fileExtension(forMIMEType mime: String) -> String? {
        let cleanMime = mime.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch cleanMime {
        // Disk Images & Programs
        case "application/x-apple-diskimage": return "dmg"
        case "application/x-xar", "application/vnd.apple.installer+xml": return "pkg"
        case "application/x-iso9660-image": return "iso"
        case "application/x-msdos-program", "application/x-msdownload", "application/vnd.microsoft.portable-executable": return "exe"
        case "application/x-msi": return "msi"
        case "application/vnd.debian.binary-package": return "deb"
        case "application/x-rpm": return "rpm"
        case "application/vnd.appimage": return "appimage"

        // Archives
        case "application/zip", "application/x-zip-compressed": return "zip"
        case "application/x-7z-compressed": return "7z"
        case "application/x-tar": return "tar"
        case "application/gzip", "application/x-gzip": return "gz"
        case "application/x-bzip2": return "bz2"
        case "application/x-xz": return "xz"
        case "application/x-rar-compressed": return "rar"

        // Documents
        case "application/pdf": return "pdf"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "application/epub+zip": return "epub"
        case "application/rtf": return "rtf"

        // Data
        case "application/vnd.sqlite3", "application/x-sqlite3": return "sqlite"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "text/yaml", "application/x-yaml": return "yaml"
        case "application/sql": return "sql"

        // Fonts
        case "font/ttf", "font/sfnt": return "ttf"
        case "font/otf": return "otf"
        case "font/woff": return "woff"
        case "font/woff2": return "woff2"

        // Media
        case "video/mp4": return "mp4"
        case "video/x-matroska": return "mkv"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "audio/mpeg": return "mp3"
        case "audio/flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"

        // Images
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"

        default:
            return nil
        }
    }

    /// Determines true file extension by inspecting the first up-to-512 binary magic bytes
    public static func detectExtension(fromHeaderData headerData: Data) -> String? {
        guard headerData.count >= 4 else { return nil }

        // 1. PDF: starts with `%PDF-`
        if headerData.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2d]) {
            return "pdf"
        }

        // 2. PKG / XAR: starts with `xar!` (0x78, 0x61, 0x72, 0x21)
        if headerData.starts(with: [0x78, 0x61, 0x72, 0x21]) {
            return "pkg"
        }

        // 3. ZIP / PK-based formats (ZIP, DOCX, XLSX, JAR): starts with `PK\x03\x04`
        if headerData.starts(with: [0x50, 0x4b, 0x03, 0x04]) || headerData.starts(with: [0x50, 0x4b, 0x05, 0x06]) {
            // Check if it's Office OpenXML
            if let headerString = String(data: headerData, encoding: .ascii) {
                if headerString.contains("word/") { return "docx" }
                if headerString.contains("xl/") { return "xlsx" }
                if headerString.contains("ppt/") { return "pptx" }
            }
            return "zip"
        }

        // 4. 7-Zip: `7z\xbc\xaf\x27\x1c`
        if headerData.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) {
            return "7z"
        }

        // 5. GZIP: `0x1f, 0x8b`
        if headerData.starts(with: [0x1f, 0x8b]) {
            return "gz"
        }

        // 6. BZIP2: `BZh` (0x42, 0x5a, 0x68)
        if headerData.starts(with: [0x42, 0x5a, 0x68]) {
            return "bz2"
        }

        // 7. XZ: `\xfd7zXZ\x00`
        if headerData.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) {
            return "xz"
        }

        // 8. RAR: `Rar!\x1a\x07`
        if headerData.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) {
            return "rar"
        }

        // 9. SQLite: `SQLite format 3\0`
        if headerData.starts(with: "SQLite format 3\0".utf8) {
            return "sqlite"
        }

        // 10. Windows PE EXE: `MZ`
        if headerData.starts(with: [0x4d, 0x5a]) {
            return "exe"
        }

        // 11. Windows MSI / Compound File: `0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1`
        if headerData.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) {
            return "msi"
        }

        // 12. Linux ELF / AppImage: `\x7fELF`
        if headerData.starts(with: [0x7f, 0x45, 0x4c, 0x46]) {
            return "appimage"
        }

        // 13. Images: PNG, JPEG, GIF, WebP
        if headerData.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            return "png"
        }
        if headerData.starts(with: [0xff, 0xd8, 0xff]) {
            return "jpg"
        }
        if headerData.starts(with: "GIF87a".utf8) || headerData.starts(with: "GIF89a".utf8) {
            return "gif"
        }
        if headerData.count >= 12,
           headerData.starts(with: [0x52, 0x49, 0x46, 0x46]), // RIFF
           headerData.subdata(in: 8..<12) == Data([0x57, 0x45, 0x42, 0x50]) { // WEBP
            return "webp"
        }

        // 13b. TIFF (little-endian `II*\0` / big-endian `MM\0*`) — ảnh khoa học
        //     rất phổ biến (ESO, NASA, thiên văn) và trước đây không nhận diện được.
        if headerData.starts(with: [0x49, 0x49, 0x2a, 0x00]) || headerData.starts(with: [0x4d, 0x4d, 0x00, 0x2a]) {
            return "tif"
        }

        // 13c. HEIC / HEIF (ISO-BMFF với brand heic/heix/hevc/hevx/mif1)
        if headerData.count >= 12,
           headerData.starts(with: [0x66, 0x74, 0x79, 0x70]), // 'ftyp'
           let brand = String(data: headerData.subdata(in: 8..<12), encoding: .ascii) {
            let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]
            if heifBrands.contains(brand) { return "heic" }
            if brand == "avif" || brand == "avis" { return "avif" }
        }

        // 14. Fonts: TTF, OTF, WOFF, WOFF2
        if headerData.starts(with: [0x00, 0x01, 0x00, 0x00]) || headerData.starts(with: "true".utf8) {
            return "ttf"
        }
        if headerData.starts(with: "OTTO".utf8) {
            return "otf"
        }
        if headerData.starts(with: "wOFF".utf8) {
            return "woff"
        }
        if headerData.starts(with: "wOF2".utf8) {
            return "woff2"
        }

        // 15. Audio/Video: MP4, MOV, MKV, MP3, FLAC
        if headerData.count >= 8, headerData.subdata(in: 4..<8) == Data("ftyp".utf8) {
            return "mp4"
        }
        if headerData.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) {
            return "mkv"
        }
        if headerData.starts(with: "ID3".utf8) || headerData.starts(with: [0xff, 0xfb]) || headerData.starts(with: [0xff, 0xf3]) {
            return "mp3"
        }
        if headerData.starts(with: "fLaC".utf8) {
            return "flac"
        }

        // 16. Apple Partition Map / Driver Descriptor Map (DMG)
        if headerData.starts(with: [0x45, 0x52]) || headerData.starts(with: "PM".utf8) {
            return "dmg"
        }

        return nil
    }

    /// Determines true file extension by inspecting binary magic bytes / signature from disk
    public static func detectExtension(fileURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize >= 4 else { return nil }

        // Read first 512 bytes
        let headerData = handle.readData(ofLength: min(512, fileSize))
        if let ext = detectExtension(fromHeaderData: headerData) {
            return ext
        }

        // Apple Disk Image (DMG - UDIF): ends with 512-byte trailer starting with `koly` (0x6b, 0x6f, 0x6c, 0x79)
        if fileSize >= 512 {
            do {
                try handle.seek(toOffset: UInt64(fileSize - 512))
                let trailer = handle.readData(ofLength: 512)
                if trailer.starts(with: [0x6b, 0x6f, 0x6c, 0x79]) {
                    return "dmg"
                }
            } catch {}
        }

        // ISO Disk Image: "CD001" at offset 32768
        if fileSize > 32773 {
            do {
                try handle.seek(toOffset: 32768)
                let isoHeader = handle.readData(ofLength: 5)
                if isoHeader == Data([0x43, 0x44, 0x30, 0x30, 0x31]) {
                    return "iso"
                }
            } catch {}
        }

        return nil
    }
}
