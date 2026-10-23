import Foundation
import DownloaderCore

/// Bộ kiểm thử nhanh 10 nguồn media — dùng chung runner với `test-app-pipeline`.
///
/// Trước đây target này có danh sách riêng (`sources.json`) đã lệch với phần còn
/// lại của repo. Nay dùng chung `scripts/media_sources_100.json` và chỉ lấy N nguồn
/// đầu để chạy nhanh (kiểm tra sức khỏe nhanh của engine tải).
///
///     swift run test-10-sources            # 10 nguồn đầu
///     swift run test-10-sources --count 30
@main
struct Test10Sources {
    static func main() async {
        var configPath = "scripts/media_sources_100.json"
        var outputPath: String?
        var destPath: String?
        var count = 10
        var tier = "quick"
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
            case "--count":
                count = args.isEmpty ? count : (Int(args.removeFirst()) ?? count)
            case "--tier":
                tier = args.isEmpty ? tier : args.removeFirst()
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

        // Lấy N nguồn đầu còn dùng được (bỏ nguồn bị policy chặn / retired).
        let subset = MediaSourceCatalog(cases: Array(catalog.cases.filter { $0.isRunnable }.prefix(count)))

        let destination = URL(fileURLWithPath: destPath ?? (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("idm_sources10_\(UUID().uuidString)"))

        let options = MediaSourceTestRunner.Options(
            headBytes: tier == "smoke" ? 512 * 1024 : 4 * 1024 * 1024,
            tailBytes: tier == "smoke" ? 256 * 1024 : 2 * 1024 * 1024,
            fullDownloadMaxBytes: 32 * 1024 * 1024,
            concurrency: 4,
            excludeTags: Set(excludeTags),
            refreshScript: "scripts/refresh_media_sources.py",
            projectRoot: FileManager.default.currentDirectoryPath
        )

        print("== Nguồn media (nhanh): \(subset.cases.count) mục | tầng \(tier)")
        let runner = MediaSourceTestRunner(options: options)
        let outcomes = await runner.run(catalog: subset, destination: destination)

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
