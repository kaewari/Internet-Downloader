import Foundation
import DownloaderCore

// MARK: - Cấu hình

struct PipelineCase: Decodable {
    let id: String
    let platform: String
    let url: String
    /// true nếu file kết quả bắt buộc phải có luồng video.
    let expectVideo: Bool
    /// true nếu file kết quả bắt buộc phải có luồng âm thanh.
    let expectAudio: Bool
    /// Ca bắt buộc (thiếu → fail) hay tuỳ chọn (thiếu → skip).
    let required: Bool
    let kind: String?
    let referer: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, url, kind, referer
        case expectVideo = "expect_video"
        case expectAudio = "expect_audio"
        case required
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        platform = try c.decode(String.self, forKey: .platform)
        url = try c.decode(String.self, forKey: .url)
        expectVideo = try c.decodeIfPresent(Bool.self, forKey: .expectVideo) ?? true
        expectAudio = try c.decodeIfPresent(Bool.self, forKey: .expectAudio) ?? false
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        referer = try c.decodeIfPresent(String.self, forKey: .referer)
    }
}

struct PipelineConfig: Decodable {
    let cases: [PipelineCase]
}

struct PipelineResult: Encodable {
    let id: String
    let platform: String
    let kind: String?
    let requestedURL: String
    let resolvedURL: String
    let status: String          // PASS | FAIL | SKIP
    let required: Bool
    let file: String?
    let sizeBytes: Int64
    let durationSeconds: Double
    let streams: [String]
    let message: String
    /// Trạng thái kiểm chứng audio mà app ghi cho task (verified/repaired/…).
    var audioState: String? = nil
}

// MARK: - Tiện ích

enum Probe {
    static var ffprobePath: String? {
        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Trả về danh sách loại stream của file (video/audio/…).
    static func streamKinds(of path: String) -> [String] {
        guard let ffprobe = ffprobePath else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }
}

/// Chờ một task tải xong (hoặc fail) với giới hạn thời gian.
final class TaskWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadTask?, Never>?
    private var finished: DownloadTask?

    func complete(_ task: DownloadTask) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            finished = task
            lock.unlock()
            cont.resume(returning: task)
        } else {
            finished = task
            lock.unlock()
        }
    }

    func wait(timeout: TimeInterval) async -> DownloadTask? {
        await withCheckedContinuation { cont in
            lock.lock()
            if let task = finished {
                finished = nil
                lock.unlock()
                cont.resume(returning: task)
                return
            }
            continuation = cont
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let cont = self.continuation {
                    self.continuation = nil
                    self.lock.unlock()
                    cont.resume(returning: nil)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }
}

// MARK: - Chế độ nguồn media

extension TestAppPipeline {
    /// Chạy kiểm thử hàng loạt nguồn media bằng engine thật của app.
    static func runSourcesMode(
        data: Data,
        configPath: String,
        outputPath: String?,
        destinationRoot: URL,
        tier: String,
        concurrency: Int,
        keepFiles: Bool,
        excludeTags: Set<String>,
        headBytes: Int64,
        tailBytes: Int64,
        fullMaxBytes: Int64
    ) async {
        guard let catalog = try? JSONDecoder().decode(MediaSourceCatalog.self, from: data) else {
            FileHandle.standardError.write(Data("Không đọc được danh sách nguồn: \(configPath)\n".utf8))
            exit(2)
        }

        // Tầng: smoke (rất nhanh) / quick (mặc định) / deep (tải trọn + decode).
        let tierConfig: (head: Int64, tail: Int64, fullMax: Int64) = switch tier {
        case "smoke": (512 * 1024, 256 * 1024, 2 * 1024 * 1024)
        case "deep": (headBytes, tailBytes, fullMaxBytes)
        default: (headBytes, tailBytes, fullMaxBytes)
        }

        let options = MediaSourceTestRunner.Options(
            headBytes: tierConfig.head,
            tailBytes: tierConfig.tail,
            fullDownloadMaxBytes: tierConfig.fullMax,
            concurrency: concurrency,
            keepFiles: keepFiles,
            excludeTags: excludeTags,
            refreshScript: "scripts/refresh_media_sources.py",
            projectRoot: FileManager.default.currentDirectoryPath
        )

        let total = catalog.cases.count
        let runnable = catalog.cases.filter { spec in
            guard spec.isRunnable else { return false }
            guard !excludeTags.isEmpty else { return true }
            return spec.tags.filter { excludeTags.contains($0) }.isEmpty
        }
        print("== Nguồn media: \(total) mục (\(runnable.count) sẽ chạy) | tầng \(tier) | \(concurrency) luồng")

        let runner = MediaSourceTestRunner(options: options)
        let outcomes = await runner.run(catalog: catalog, destination: destinationRoot)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(outcomes)) ?? Data("[]".utf8)
        if let outputPath {
            try? json.write(to: URL(fileURLWithPath: outputPath))
            print("Kết quả: \(outputPath)")
        } else {
            FileHandle.standardOutput.write(json)
        }

        let passes = outcomes.filter { $0.status == "PASS" }.count
        let fails = outcomes.filter { $0.status == "FAIL" }.count
        let skips = outcomes.filter { $0.status == "SKIP" }.count
        print("\nTổng: \(passes) PASS / \(fails) FAIL / \(skips) SKIP / \(outcomes.count) ca")
        exit(fails > 0 ? 1 : 0)
    }
}

// MARK: - Chạy

@main
struct TestAppPipeline {
    static func main() async {
        var configPath = "scripts/live_platform_sources.json"
        var outputPath: String?
        var timeout = 180.0
        var destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("idm_app_pipeline_\(UUID().uuidString)")
        var onlyPlatform: String?
        var tier = "quick"
        var concurrency = 8
        var keepFiles = false
        var excludeTags: [String] = []
        var excludeHosts: [String] = []
        var headBytes: Int64 = 4 * 1024 * 1024
        var tailBytes: Int64 = 2 * 1024 * 1024
        var fullMaxBytes: Int64 = 32 * 1024 * 1024

        var args = Array(CommandLine.arguments.dropFirst())
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--config":
                configPath = args.isEmpty ? configPath : args.removeFirst()
            case "--output":
                outputPath = args.isEmpty ? nil : args.removeFirst()
            case "--timeout":
                timeout = args.isEmpty ? timeout : (Double(args.removeFirst()) ?? timeout)
            case "--dest":
                let raw = args.isEmpty ? "" : args.removeFirst()
                destinationRoot = URL(fileURLWithPath: raw)
            case "--platform":
                onlyPlatform = args.isEmpty ? nil : args.removeFirst()
            case "--tier":
                tier = args.isEmpty ? tier : args.removeFirst()
            case "--concurrency":
                concurrency = args.isEmpty ? concurrency : (Int(args.removeFirst()) ?? concurrency)
            case "--keep-files":
                keepFiles = true
            case "--exclude-tag":
                if !args.isEmpty { excludeTags.append(args.removeFirst()) }
            case "--exclude-host":
                if !args.isEmpty { excludeHosts.append(args.removeFirst()) }
            case "--head-bytes":
                headBytes = args.isEmpty ? headBytes : (Int64(args.removeFirst()) ?? headBytes)
            case "--tail-bytes":
                tailBytes = args.isEmpty ? tailBytes : (Int64(args.removeFirst()) ?? tailBytes)
            case "--full-max-bytes":
                fullMaxBytes = args.isEmpty ? fullMaxBytes : (Int64(args.removeFirst()) ?? fullMaxBytes)
            default:
                break
            }
        }

        guard let data = FileManager.default.contents(atPath: configPath) else {
            FileHandle.standardError.write(Data("Không đọc được cấu hình: \(configPath)\n".utf8))
            exit(2)
        }

        try? FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        // Cấu hình nguồn media (có trường `access`) và cấu hình ma trận nền tảng
        // dùng hai kiểu khác nhau → tự nhận diện.
        if MediaSourceCatalog.isSourceCatalog(data) {
            await runSourcesMode(
                data: data,
                configPath: configPath,
                outputPath: outputPath,
                destinationRoot: destinationRoot,
                tier: tier,
                concurrency: concurrency,
                keepFiles: keepFiles,
                excludeTags: Set(excludeTags),
                headBytes: headBytes,
                tailBytes: tailBytes,
                fullMaxBytes: fullMaxBytes
            )
            return
        }

        guard let config = try? JSONDecoder().decode(PipelineConfig.self, from: data) else {
            FileHandle.standardError.write(Data("Không đọc được cấu hình: \(configPath)\n".utf8))
            exit(2)
        }

        let manager = DownloadManager(dbPath: destinationRoot.appendingPathComponent("pipeline.sqlite").path)

        var results: [PipelineResult] = []

        for testCase in config.cases {
            if let onlyPlatform, onlyPlatform.lowercased() != testCase.platform.lowercased() { continue }
            guard let url = URL(string: testCase.url) else {
                results.append(PipelineResult(
                    id: testCase.id, platform: testCase.platform, kind: testCase.kind,
                    requestedURL: testCase.url, resolvedURL: "", status: "SKIP", required: testCase.required,
                    file: nil, sizeBytes: 0, durationSeconds: 0, streams: [],
                    message: "URL không hợp lệ"
                ))
                continue
            }

            print("==> [\(testCase.platform)] \(testCase.id) — \(testCase.url)")
            let waiter = TaskWaiter()
            let started = Date()
            let caseFolder = destinationRoot.appendingPathComponent(testCase.id)
            try? FileManager.default.createDirectory(at: caseFolder, withIntermediateDirectories: true)

            do {
                let task = try manager.createNewTask(
                    url: url,
                    destinationFolder: caseFolder,
                    referrer: testCase.referer
                )
                manager.onDownloadCompleted = { finished in waiter.complete(finished) }
                manager.onDownloadFailed = { failed in waiter.complete(failed) }
                manager.startDownload(taskId: task.id)

                let finished = await waiter.wait(timeout: timeout)
                let elapsed = Date().timeIntervalSince(started)
                let resolvedURL = manager.getTask(id: task.id)?.url.absoluteString ?? testCase.url

                guard let finished else {
                    results.append(PipelineResult(
                        id: testCase.id, platform: testCase.platform, kind: testCase.kind,
                        requestedURL: testCase.url, resolvedURL: resolvedURL, status: "FAIL", required: testCase.required,
                        file: nil, sizeBytes: 0, durationSeconds: elapsed, streams: [],
                        message: "Timeout sau \(Int(timeout))s"
                    ))
                    print("    [FAIL] Timeout \(Int(timeout))s")
                    continue
                }

                guard finished.status == .completed else {
                    let reason = finished.errorMessage ?? "Không rõ nguyên nhân"
                    results.append(PipelineResult(
                        id: testCase.id, platform: testCase.platform, kind: testCase.kind,
                        requestedURL: testCase.url, resolvedURL: resolvedURL, status: "FAIL", required: testCase.required,
                        file: nil, sizeBytes: 0, durationSeconds: elapsed, streams: [],
                        message: reason
                    ))
                    print("    [FAIL] \(reason)")
                    continue
                }

                let filePath = finished.finalFilePath.path
                let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let streams = Probe.streamKinds(of: filePath)

                var problems: [String] = []
                if size <= 0 { problems.append("file rỗng") }
                if testCase.expectVideo, !streams.contains("video") {
                    problems.append("thiếu luồng video (chỉ có: \(streams.isEmpty ? "không xác định" : streams.joined(separator: ",")))")
                }
                if testCase.expectAudio, !streams.contains("audio") {
                    problems.append("thiếu luồng audio (chỉ có: \(streams.isEmpty ? "không xác định" : streams.joined(separator: ",")))")
                }

                let status = problems.isEmpty ? "PASS" : "FAIL"
                let message = problems.isEmpty
                    ? "OK — \(streams.joined(separator: "+"))"
                    : problems.joined(separator: "; ")

                results.append(PipelineResult(
                    id: testCase.id, platform: testCase.platform, kind: testCase.kind,
                    requestedURL: testCase.url, resolvedURL: resolvedURL, status: status, required: testCase.required,
                    file: filePath, sizeBytes: size, durationSeconds: elapsed, streams: streams,
                    message: message, audioState: finished.audioState?.rawValue
                ))
                print("    [\(status)] \(message) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) — \(String(format: "%.2fs", elapsed))")
            } catch {
                results.append(PipelineResult(
                    id: testCase.id, platform: testCase.platform, kind: testCase.kind,
                    requestedURL: testCase.url, resolvedURL: testCase.url, status: "FAIL", required: testCase.required,
                    file: nil, sizeBytes: 0, durationSeconds: Date().timeIntervalSince(started), streams: [],
                    message: error.localizedDescription
                ))
                print("    [FAIL] \(error.localizedDescription)")
            }
        }

        manager.shutdown()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(results)) ?? Data("[]".utf8)
        if let outputPath {
            try? json.write(to: URL(fileURLWithPath: outputPath))
            print("\nKết quả: \(outputPath)")
        } else {
            FileHandle.standardOutput.write(json)
        }

        let failures = results.filter { $0.status == "FAIL" }.count
        let passes = results.filter { $0.status == "PASS" }.count
        print("\nTổng: \(passes) PASS / \(failures) FAIL / \(results.count) ca")
        exit(failures > 0 ? 1 : 0)
    }
}
