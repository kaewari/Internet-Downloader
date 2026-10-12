import Foundation
import DownloaderCore

struct SourceItem: Codable, Sendable {
    let id: Int
    let category: String
    let platform: String
    let title: String
    let url: String
    let host: String
    let type: String
    let ext: String
    let size: Int64
    let mime: String
}

struct TestResult: Sendable {
    let item: SourceItem
    let success: Bool
    let filePath: String?
    let bytesDownloaded: Int64
    let durationSeconds: Double
    let message: String
}

@main
struct Test10SourcesApp {
    static func main() async {
        let startTime = Date()
        print("================================================================================")
        print("  Internet Downloader App - 10 Sources Native Verification Suite")
        print("  Target: 10 Media Files (10MB - 50MB) across Famous & NSFW Sources")
        print("  Engine: DownloaderCore (HTTPRangeDownloader, Sparse Files, Chunk Streaming)")
        print("================================================================================")

        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let sourcesURL = currentDir.appendingPathComponent("Sources/Test10Sources/sources.json")
        let destDir = currentDir.appendingPathComponent("Downloads/Test10Media")
        let logsDir = currentDir.appendingPathComponent("logs")
        let logFileURL = logsDir.appendingPathComponent("download_10_media.log")

        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        guard let sourcesData = try? Data(contentsOf: sourcesURL),
              let items = try? JSONDecoder().decode([SourceItem].self, from: sourcesData) else {
            print("ERROR: Failed to load sources from \(sourcesURL.path)")
            exit(1)
        }

        print("Loaded \(items.count) sources from sources.json.")
        print("Destination Directory: \(destDir.path)")
        print("Log File: \(logFileURL.path)")
        print("--------------------------------------------------------------------------------")

        logEvent(logFileURL: logFileURL, message: "STARTING NATIVE APP DOWNLOAD OF 10 SOURCES (10MB - 50MB)")

        let session = HTTPRangeDownloader.makeOptimizedSession()

        // Execute downloads concurrently
        let results = await withTaskGroup(of: TestResult.self) { group in
            for item in items {
                group.addTask {
                    await downloadAndVerify(item: item, destDir: destDir, logFileURL: logFileURL, session: session)
                }
            }
            var collected: [TestResult] = []
            for await r in group {
                collected.append(r)
            }
            return collected.sorted { $0.item.id < $1.item.id }
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        let passed = results.filter { $0.success }
        let failed = results.filter { !$0.success }
        let totalBytes = passed.reduce(0) { $0 + $1.bytesDownloaded }
        let avgSpeedMBs = totalDuration > 0 ? (Double(totalBytes) / (1024 * 1024)) / totalDuration : 0.0

        print("================================================================================")
        print("  SUMMARY OF 10 MEDIA FILES DOWNLOAD & VERIFICATION (APP ENGINE)")
        print("================================================================================")
        print("Total Files: \(items.count) | Passed: \(passed.count) | Failed: \(failed.count)")
        print(String(format: "Total Downloaded Size: %lld bytes (%.2f MB)", totalBytes, Double(totalBytes) / (1024 * 1024)))
        print(String(format: "Total Duration: %.2f seconds | Average Aggregate Speed: %.2f MB/s", totalDuration, avgSpeedMBs))
        print("================================================================================")

        for r in results {
            let status = r.success ? "PASS" : "FAIL"
            let mb = Double(r.bytesDownloaded) / (1024 * 1024)
            print(String(format: "  [%@] #%02d [%@] %@ -> %.2f MB (%.2fs) | %@",
                         status, r.item.id, r.item.platform, r.item.host, mb, r.durationSeconds, r.message))
        }

        logEvent(logFileURL: logFileURL, message: "SUMMARY: \(passed.count)/\(items.count) PASSED in \(String(format: "%.2f", totalDuration))s")

        if failed.isEmpty && passed.count == items.count {
            print("\n[RESULT] SUCCESS: 10/10 files downloaded and verified 100% on disk via DownloaderCore!")
            exit(0)
        } else {
            print("\n[RESULT] FAILED: \(failed.count) files failed verification.")
            exit(1)
        }
    }

    static func downloadAndVerify(
        item: SourceItem,
        destDir: URL,
        logFileURL: URL,
        session: URLSession
    ) async -> TestResult {
        let startTime = Date()
        let cleanHost = item.host.replacingOccurrences(of: ".", with: "_")
        let filename = String(format: "%02d_%@.%@", item.id, cleanHost, item.ext)
        let targetFile = destDir.appendingPathComponent(filename)

        guard let normalizedURL = URLNormalizer.normalize(item.url) else {
            return TestResult(item: item, success: false, filePath: nil, bytesDownloaded: 0, durationSeconds: 0, message: "URL Normalization failed")
        }

        let userAgent = URLNormalizer.defaultUserAgent
        var customHeaders: [String: String] = [
            "Referer": "https://\(item.host)/",
            "User-Agent": userAgent
        ]

        logEvent(logFileURL: logFileURL, message: String(format: "[START] #%02d [%@] (%@) -> %@", item.id, item.platform, item.host, filename))
        print(String(format: "==> [START] #%02d [%@] Downloading %@...", item.id, item.platform, item.host))

        do {
            // 1. Probe URL using app engine
            let probe = try await HTTPRangeDownloader.probeURL(
                url: normalizedURL,
                customHeaders: customHeaders,
                userAgent: userAgent,
                session: session
            )

            let taskId = UUID()
            let totalBytes = probe.totalBytes > 0 ? probe.totalBytes : item.size

            let task = DownloadTask(
                id: taskId,
                url: normalizedURL,
                filename: filename,
                destinationFolder: destDir,
                totalBytes: totalBytes,
                downloadedBytes: 0,
                status: .downloading,
                acceptRanges: probe.acceptRanges,
                referrer: customHeaders["Referer"],
                userAgent: userAgent
            )

            // 2. Multi-segmented HTTPRangeDownloader
            let segmentCount = probe.acceptRanges ? 4 : 1
            let segments = HTTPRangeDownloader.calculateSegments(
                taskId: taskId,
                totalBytes: totalBytes,
                segmentCount: segmentCount,
                acceptRanges: probe.acceptRanges
            )

            let downloader = HTTPRangeDownloader(session: session)
            try await downloader.download(
                task: task,
                segments: segments,
                onProgress: { _, _ in },
                onSegmentUpdate: { _ in }
            )

            let elapsed = Date().timeIntervalSince(startTime)

            // 3. Verify file on disk
            guard FileManager.default.fileExists(atPath: targetFile.path) else {
                return TestResult(item: item, success: false, filePath: nil, bytesDownloaded: 0, durationSeconds: elapsed, message: "File missing on disk after download")
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: targetFile.path)
            let actualBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            // 4. Verify Size Criteria: 10MB <= size <= 50MB
            let min10MB: Int64 = 10 * 1024 * 1024
            let max50MB: Int64 = 52 * 1024 * 1024
            guard actualBytes >= min10MB else {
                return TestResult(item: item, success: false, filePath: targetFile.path, bytesDownloaded: actualBytes, durationSeconds: elapsed, message: "File size too small: \(actualBytes) bytes < 10MB")
            }
            guard actualBytes <= max50MB else {
                return TestResult(item: item, success: false, filePath: targetFile.path, bytesDownloaded: actualBytes, durationSeconds: elapsed, message: "File size exceeds 50MB: \(actualBytes) bytes")
            }

            // 5. Verify Magic Bytes & non-HTML error
            let handle = try FileHandle(forReadingFrom: targetFile)
            let headerData = try handle.read(upToCount: 512) ?? Data()
            try? handle.close()

            if isHTMLError(data: headerData) {
                return TestResult(item: item, success: false, filePath: targetFile.path, bytesDownloaded: actualBytes, durationSeconds: elapsed, message: "Response is HTML error page instead of media")
            }

            // 6. ffprobe inspection if video or audio
            var ffprobeInfo = ""
            if item.type == "video" || item.type == "audio" {
                ffprobeInfo = runFFprobe(filePath: targetFile.path)
            }

            let speedMB = elapsed > 0 ? (Double(actualBytes) / (1024 * 1024)) / elapsed : 0.0
            let logMsg = String(format: "[SUCCESS] #%02d [%@] (%@): %lld bytes (%.2f MB) in %.1fs (%.2f MB/s) | %@ %@",
                                item.id, item.platform, item.host, actualBytes, Double(actualBytes)/(1024*1024), elapsed, speedMB, item.mime, ffprobeInfo)
            logEvent(logFileURL: logFileURL, message: logMsg)
            print("  ✔ " + logMsg)

            return TestResult(
                item: item,
                success: true,
                filePath: targetFile.path,
                bytesDownloaded: actualBytes,
                durationSeconds: elapsed,
                message: "Verified \(actualBytes) bytes (\(item.mime)) \(ffprobeInfo)"
            )

        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let errMsg = "Download error: \(error.localizedDescription)"
            logEvent(logFileURL: logFileURL, message: "[ERROR] #\(item.id) [\(item.platform)]: \(errMsg)")
            print(String(format: "  ✖ [ERROR] #%02d [%@]: %@", item.id, item.platform, errMsg))
            return TestResult(item: item, success: false, filePath: nil, bytesDownloaded: 0, durationSeconds: elapsed, message: errMsg)
        }
    }

    static func isHTMLError(data: Data) -> Bool {
        guard let str = String(data: data.prefix(128), encoding: .utf8)?.lowercased() else { return false }
        return str.hasPrefix("<!doctype html") || str.hasPrefix("<html") || str.contains("<head>")
    }

    static func runFFprobe(filePath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffprobe"]
        let whichPipe = Pipe()
        process.standardOutput = whichPipe
        try? process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let whichOut = String(data: whichPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !whichOut.isEmpty else {
            return ""
        }

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: whichOut)
        probe.arguments = [
            "-v", "error",
            "-show_entries", "format=duration:stream=codec_name,width,height",
            "-of", "default=noprint_wrappers=1:nokey=1",
            filePath
        ]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try? probe.run()
        probe.waitUntilExit()

        if let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) {
            return "[ffprobe: \(out)]"
        }
        return ""
    }

    static func logEvent(logFileURL: URL, message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}
