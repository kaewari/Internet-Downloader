import Foundation
import DownloaderCore

/// Bộ kiểm thử 100+ nguồn media thật — **dùng chung** với `test-app-pipeline`.
///
/// Danh sách nguồn nằm ở `scripts/media_sources_100.json` (một nguồn sự thật duy
/// nhất trong repo, không còn danh sách hardcode trong code). Logic tải + kiểm
/// chứng nằm ở `DownloaderCore/Testing/MediaSourceTestRunner.swift` — dùng engine
/// thật của app: `MediaURLResolver` + `HTTPRangeDownloader` + `FileTypeDetector`
/// + `ffprobe`.
///
///     swift run test-100-sources
///     swift run test-100-sources --tier deep --concurrency 4
///     swift run test-100-sources --exclude-tag nsfw
@main
struct Test100Sources {
    static func main() async {
        var configPath = "scripts/media_sources_100.json"
        var outputPath: String?
        var destPath: String?
        var tier = "quick"
        var concurrency = 8
        var keepFiles = false
        var excludeTags: [String] = []

        var args = Array(CommandLine.arguments.dropFirst())
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--config":
                configPath = args.isEmpty ? configPath : args.removeFirst()
            case "--output":
                outputPath = args.isEmpty ? nil : args.removeFirst()
            case "--dest":
                destPath = args.isEmpty ? nil : args.removeFirst()
            case "--tier":
                tier = args.isEmpty ? tier : args.removeFirst()
            case "--concurrency":
                concurrency = args.isEmpty ? concurrency : (Int(args.removeFirst()) ?? concurrency)
            case "--keep-files":
                keepFiles = true
            case "--exclude-tag":
                if !args.isEmpty { excludeTags.append(args.removeFirst()) }
            default:
                break
            }
        }

        guard let data = FileManager.default.contents(atPath: configPath),
              let catalog = try? JSONDecoder().decode(MediaSourceCatalog.self, from: data) else {
            FileHandle.standardError.write(Data("Không đọc được danh sách nguồn: \(configPath)\n".utf8))
            exit(2)
        }

        let destination = URL(fileURLWithPath: destPath ?? (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("idm_sources_\(UUID().uuidString)"))

        let tierConfig: (head: Int64, tail: Int64, fullMax: Int64) = switch tier {
        case "smoke": (512 * 1024, 256 * 1024, 2 * 1024 * 1024)
        case "deep": (4 * 1024 * 1024, 2 * 1024 * 1024, 32 * 1024 * 1024)
        default: (4 * 1024 * 1024, 2 * 1024 * 1024, 32 * 1024 * 1024)
        }

        let options = MediaSourceTestRunner.Options(
            headBytes: tierConfig.head,
            tailBytes: tierConfig.tail,
            fullDownloadMaxBytes: tierConfig.fullMax,
            concurrency: concurrency,
            keepFiles: keepFiles,
            excludeTags: Set(excludeTags),
            refreshScript: "scripts/refresh_media_sources.py",
            projectRoot: FileManager.default.currentDirectoryPath
        )

        print("==========================================================")
        print("  Internet Downloader — kiểm thử nguồn media (tầng \(tier))")
        print("  Danh sách: \(configPath) — \(catalog.cases.count) mục")
        print("==========================================================")

        let runner = MediaSourceTestRunner(options: options)
        let outcomes = await runner.run(catalog: catalog, destination: destination)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(outcomes)) ?? Data("[]".utf8)
        if let outputPath {
            try? json.write(to: URL(fileURLWithPath: outputPath))
            print("Kết quả: \(outputPath)")
        }

        let passes = outcomes.filter { $0.status == "PASS" }.count
        let fails = outcomes.filter { $0.status == "FAIL" }.count
        let skips = outcomes.filter { $0.status == "SKIP" }.count
        print("\nTổng: \(passes) PASS / \(fails) FAIL / \(skips) SKIP / \(outcomes.count) ca")
        exit(fails > 0 ? 1 : 0)
    }
}
