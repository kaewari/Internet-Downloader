import Foundation

public struct HLSSegmentInfo: Sendable {
    public let uri: URL
    public let duration: Double
    public let index: Int

    public init(uri: URL, duration: Double, index: Int) {
        self.uri = uri
        self.duration = duration
        self.index = index
    }
}

public actor HLSDownloader {
    private let session: URLSession
    private let speedTracker = SpeedTracker()
    private var isCancelled = false

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func parsePlaylist(content: String, baseURL: URL) throws -> [HLSSegmentInfo] {
        var segments: [HLSSegmentInfo] = []
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        var currentDuration: Double = 0.0
        var segmentIndex = 0

        for line in lines {
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                let durationStr = line.dropFirst("#EXTINF:".count).split(separator: ",")[0]
                currentDuration = Double(durationStr) ?? 0.0
            } else if !line.hasPrefix("#") {
                let segmentURL: URL
                if line.lowercased().hasPrefix("http://") || line.lowercased().hasPrefix("https://") {
                    segmentURL = URL(string: line) ?? baseURL
                } else {
                    segmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL ?? baseURL
                }
                segments.append(HLSSegmentInfo(uri: segmentURL, duration: currentDuration, index: segmentIndex))
                segmentIndex += 1
            }
        }

        return segments
    }

    public func download(
        playlistURL: URL,
        destinationFile: URL,
        tempDirectory: URL,
        maxConcurrency: Int = 4,
        onProgress: @escaping @Sendable (Int, Int, Double) -> Void // (downloadedSegments, totalSegments, speed)
    ) async throws {
        isCancelled = false
        speedTracker.reset()

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: tempDirectory.path) {
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        }

        // 1. Fetch playlist content
        let (playlistData, _) = try await session.data(from: playlistURL)
        guard let playlistString = String(data: playlistData, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        var segments = try Self.parsePlaylist(content: playlistString, baseURL: playlistURL)

        // If it's a master playlist pointing to child playlists, resolve the first/best one
        if segments.isEmpty && playlistString.contains("#EXT-X-STREAM-INF") {
            let lines = playlistString.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            for line in lines where !line.isEmpty && !line.hasPrefix("#") {
                let childURL = URL(string: line, relativeTo: playlistURL)?.absoluteURL ?? playlistURL
                let (childData, _) = try await session.data(from: childURL)
                if let childStr = String(data: childData, encoding: .utf8) {
                    segments = try Self.parsePlaylist(content: childStr, baseURL: childURL)
                    if !segments.isEmpty { break }
                }
            }
        }

        guard !segments.isEmpty else {
            throw NSError(domain: "HLSDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "No media segments found in playlist"])
        }

        let totalSegments = segments.count
        var downloadedCount = 0

        // Download segments in controlled concurrent batches
        let partFiles = segments.map { tempDirectory.appendingPathComponent(String(format: "hls_seg_%05d.ts", $0.index)) }

        for chunk in segments.chunked(into: maxConcurrency) {
            if isCancelled { break }

            try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
                for seg in chunk {
                    let dest = partFiles[seg.index]
                    group.addTask { [self] in
                        let bytesCount = try await self.downloadSingleSegment(from: seg.uri, to: dest)
                        return (seg.index, bytesCount)
                    }
                }

                for try await (_, bytesCount) in group {
                    downloadedCount += 1
                    speedTracker.record(bytes: bytesCount)
                    let speed = speedTracker.currentSpeed()
                    onProgress(downloadedCount, totalSegments, speed)
                }
            }
        }

        // Concatenate all downloaded segments into destination file
        let targetDir = destinationFile.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destinationFile.path) {
            try fileManager.removeItem(at: destinationFile)
        }

        fileManager.createFile(atPath: destinationFile.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destinationFile)
        defer { try? outHandle.close() }

        for partFile in partFiles {
            guard fileManager.fileExists(atPath: partFile.path) else { continue }
            let inHandle = try FileHandle(forReadingFrom: partFile)
            defer { try? inHandle.close() }
            while let data = try inHandle.read(upToCount: 512 * 1024), !data.isEmpty {
                try outHandle.write(contentsOf: data)
            }
        }

        try? fileManager.removeItem(at: tempDirectory)
    }

    private func downloadSingleSegment(from url: URL, to destination: URL) async throws -> Int64 {
        let (data, _) = try await session.data(from: url)
        try data.write(to: destination)
        return Int64(data.count)
    }

    public func cancel() {
        isCancelled = true
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
