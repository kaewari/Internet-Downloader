import Foundation

public enum AssemblerError: LocalizedError {
    case missingSegmentFile(URL)
    case segmentSizeMismatch(segment: Int, expected: Int64, actual: Int64)
    case totalSizeMismatch(expected: Int64, actual: Int64)
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSegmentFile(let url):
            return "Missing segment file: \(url.lastPathComponent)"
        case .segmentSizeMismatch(let seg, let expected, let actual):
            return "Segment \(seg) size mismatch: expected \(expected), actual \(actual)"
        case .totalSizeMismatch(let expected, let actual):
            return "Assembled file size mismatch: expected \(expected), actual \(actual)"
        case .fileWriteFailed(let msg):
            return "Failed writing assembled file: \(msg)"
        }
    }
}

public struct FileAssembler: Sendable {
    public init() {}

    public func assemble(
        segments: [DownloadSegment],
        tempDirectory: URL,
        destinationFile: URL,
        expectedTotalBytes: Int64
    ) throws {
        let sortedSegments = segments.sorted { $0.index < $1.index }
        let fileManager = FileManager.default

        // Ensure target directory exists
        let targetDirectory = destinationFile.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        }

        // If destination file exists, remove it first
        if fileManager.fileExists(atPath: destinationFile.path) {
            try fileManager.removeItem(at: destinationFile)
        }

        fileManager.createFile(atPath: destinationFile.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destinationFile)
        defer {
            try? outputHandle.close()
        }

        let bufferSize = 1024 * 1024 // 1 MB buffer
        var totalWritten: Int64 = 0

        for segment in sortedSegments {
            let partFile = segment.tempFile(in: tempDirectory)
            guard fileManager.fileExists(atPath: partFile.path) else {
                throw AssemblerError.missingSegmentFile(partFile)
            }

            let attributes = try fileManager.attributesOfItem(atPath: partFile.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if actualSize != segment.downloadedBytes {
                throw AssemblerError.segmentSizeMismatch(
                    segment: segment.index,
                    expected: segment.downloadedBytes,
                    actual: actualSize
                )
            }

            let inputHandle = try FileHandle(forReadingFrom: partFile)
            defer {
                try? inputHandle.close()
            }

            while true {
                let chunk = try inputHandle.read(upToCount: bufferSize)
                guard let data = chunk, !data.isEmpty else { break }
                try outputHandle.write(contentsOf: data)
                totalWritten += Int64(data.count)
            }
        }

        if expectedTotalBytes > 0 && totalWritten != expectedTotalBytes {
            try? fileManager.removeItem(at: destinationFile)
            throw AssemblerError.totalSizeMismatch(expected: expectedTotalBytes, actual: totalWritten)
        }

        // Clean up temporary directory
        try? fileManager.removeItem(at: tempDirectory)
    }
}
