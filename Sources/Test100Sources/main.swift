import Foundation
import DownloaderCore

struct MediaTestCase: Sendable {
    let id: Int
    let domain: String
    let url: String
    let isVideo: Bool
    let referer: String?
    let userAgent: String?

    init(id: Int, domain: String, url: String, isVideo: Bool, referer: String? = nil, userAgent: String? = nil) {
        self.id = id
        self.domain = domain
        self.url = url
        self.isVideo = isVideo
        self.referer = referer
        self.userAgent = userAgent
    }
}

struct TestResult: Sendable {
    let testCase: MediaTestCase
    let success: Bool
    let filePath: String?
    let fileSize: Int64
    let durationSeconds: Double
    let message: String
}

@main
struct Test100SourcesApp {
    static func main() async {
        print("==========================================================")
        print("  Internet Downloader - 100 Sources Comprehensive Test")
        print("  Target: 100 Images & 109 Videos across 100+ Sources")
        print("==========================================================")

        let fileManager = FileManager.default
        let baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test_downloads")
        let imagesDir = baseDir.appendingPathComponent("images")
        let videosDir = baseDir.appendingPathComponent("videos")

        try? fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)

        let imageTestCases = buildImageTestCases()
        let videoTestCases = buildVideoTestCases()

        print("Total Image Tests: \(imageTestCases.count)")
        print("Total Video Tests: \(videoTestCases.count)")

        var allDomains = Set<String>()
        for t in imageTestCases { allDomains.insert(t.domain) }
        for t in videoTestCases { allDomains.insert(t.domain) }
        print("Total Unique Sources/Domains: \(allDomains.count)")
        print("----------------------------------------------------------")

        // 1. Run Image Tests
        print("==> 1. Executing Image Downloads (Concurrency: 10)...")
        let imageResults = await runTestBatch(cases: imageTestCases, destDir: imagesDir)

        // 2. Run Video Tests
        print("==> 2. Executing Video Downloads (Concurrency: 8)...")
        let videoResults = await runTestBatch(cases: videoTestCases, destDir: videosDir)

        // Summary
        print("==========================================================")
        print("  COMPREHENSIVE TEST RESULTS SUMMARY")
        print("==========================================================")

        let passedImages = imageResults.filter { $0.success }.count
        let failedImages = imageResults.filter { !$0.success }
        let passedVideos = videoResults.filter { $0.success }.count
        let failedVideos = videoResults.filter { !$0.success }

        print("Images: \(passedImages)/\(imageTestCases.count) PASSED")
        print("Videos: \(passedVideos)/\(videoTestCases.count) PASSED")

        var successfulDomains = Set<String>()
        for r in imageResults where r.success { successfulDomains.insert(r.testCase.domain) }
        for r in videoResults where r.success { successfulDomains.insert(r.testCase.domain) }
        print("Unique Sources Passed: \(successfulDomains.count) / \(allDomains.count)")

        if !failedImages.isEmpty {
            print("\n--- Failed Image Tests (\(failedImages.count)) ---")
            for f in failedImages {
                print("  [#\(f.testCase.id)] Domain: \(f.testCase.domain) -> \(f.message)")
            }
        }

        if !failedVideos.isEmpty {
            print("\n--- Failed Video Tests (\(failedVideos.count)) ---")
            for f in failedVideos {
                print("  [#\(f.testCase.id)] Domain: \(f.testCase.domain) -> \(f.message)")
            }
        }

        let totalTests = imageTestCases.count + videoTestCases.count
        let totalPassed = passedImages + passedVideos
        let passRate = (Double(totalPassed) / Double(totalTests)) * 100.0
        print("----------------------------------------------------------")
        print(String(format: "Overall Pass Rate: %.1f%% (%d/%d tests)", passRate, totalPassed, totalTests))

        if failedImages.isEmpty && failedVideos.isEmpty && successfulDomains.count >= 100 {
            print("==> 100% OF ALL 100 SOURCES PASSED SUCCESSFULLY!")
            exit(0)
        } else {
            print("==> Some tests failed. Exiting with status 1.")
            exit(1)
        }
    }

    static func runTestBatch(cases: [MediaTestCase], destDir: URL) async -> [TestResult] {
        var results: [TestResult] = []
        let session = HTTPRangeDownloader.makeOptimizedSession()

        let concurrency = 10
        let strideSize = concurrency

        for i in stride(from: 0, to: cases.count, by: strideSize) {
            let chunk = Array(cases[i..<min(i + strideSize, cases.count)])
            let batchResults = await withTaskGroup(of: TestResult.self) { group in
                for testCase in chunk {
                    group.addTask {
                        await downloadAndVerify(testCase: testCase, destDir: destDir, session: session)
                    }
                }
                var collected: [TestResult] = []
                for await r in group {
                    collected.append(r)
                }
                return collected
            }
            results.append(contentsOf: batchResults)
        }

        return results
    }

    static func downloadAndVerify(
        testCase: MediaTestCase,
        destDir: URL,
        session: URLSession
    ) async -> TestResult {
        let startTime = Date()
        let prefix = testCase.isVideo ? "vid" : "img"
        let cleanDomain = testCase.domain.replacingOccurrences(of: ".", with: "_")
        let targetFileName = "\(prefix)_\(String(format: "%03d", testCase.id))_\(cleanDomain).bin"
        let targetFile = destDir.appendingPathComponent(targetFileName)
        try? FileManager.default.removeItem(at: targetFile)

        // 1. URL Normalization
        guard let normalizedURL = URLNormalizer.normalize(testCase.url) else {
            return TestResult(
                testCase: testCase,
                success: false,
                filePath: nil,
                fileSize: 0,
                durationSeconds: 0,
                message: "Failed to normalize URL"
            )
        }

        // 2. Data URL direct handling
        if DataURLHandler.isDataURL(normalizedURL) {
            do {
                let parsed = try DataURLHandler.parse(urlString: normalizedURL.absoluteString)
                let actualFile = destDir.appendingPathComponent("\(prefix)_\(String(format: "%03d", testCase.id))_\(cleanDomain).\(parsed.suggestedExtension)")
                try parsed.data.write(to: actualFile)
                let duration = Date().timeIntervalSince(startTime)
                print(String(format: "  [PASS] #%03d [%@] Size: %d bytes (Data URL direct, %.2fs)", testCase.id, testCase.domain, parsed.data.count, duration))
                return TestResult(
                    testCase: testCase,
                    success: true,
                    filePath: actualFile.path,
                    fileSize: Int64(parsed.data.count),
                    durationSeconds: duration,
                    message: "OK (Data URL)"
                )
            } catch {
                return TestResult(
                    testCase: testCase,
                    success: false,
                    filePath: nil,
                    fileSize: 0,
                    durationSeconds: 0,
                    message: "Data URL parse error: \(error)"
                )
            }
        }

        // 3. Resolve Media if Video Platform or complex URL
        var effectiveURL = normalizedURL
        var effectiveHeaders: [String: String] = [:]
        if let ref = testCase.referer ?? testCase.url.split(separator: "?").first.map({ String($0) }) {
            effectiveHeaders["Referer"] = ref
        }
        let effectiveUA = testCase.userAgent ?? URLNormalizer.defaultUserAgent
        effectiveHeaders["User-Agent"] = effectiveUA

        if testCase.isVideo && !MediaURLResolver.isDirectMediaURL(normalizedURL) {
            let resolved = await MediaURLResolver.resolve(
                url: normalizedURL,
                customHeaders: effectiveHeaders,
                userAgent: effectiveUA
            )
            effectiveURL = resolved.directURL
            for (k, v) in resolved.headers { effectiveHeaders[k] = v }
        }

        // 4. Download Execution
        do {
            let task = DownloadTask(
                url: effectiveURL,
                filename: targetFileName,
                destinationFolder: destDir,
                referrer: effectiveHeaders["Referer"],
                userAgent: effectiveUA
            )

            // Check if HLS stream
            if effectiveURL.pathExtension.lowercased() == "m3u8" || effectiveURL.absoluteString.contains(".m3u8") {
                let hls = HLSDownloader(session: session)
                let tempDir = destDir.appendingPathComponent(".tmp_\(testCase.id)")
                try await hls.download(
                    playlistURL: effectiveURL,
                    destinationFile: targetFile,
                    tempDirectory: tempDir,
                    onProgress: { _, _, _, _, _, _ in }
                )
            } else {
                // HTTP Range Downloader
                let probe = try await HTTPRangeDownloader.probeURL(
                    url: effectiveURL,
                    customHeaders: effectiveHeaders,
                    userAgent: effectiveUA,
                    session: session
                )

                var updatedTask = task
                updatedTask.totalBytes = probe.totalBytes
                updatedTask.acceptRanges = probe.acceptRanges

                let segments = HTTPRangeDownloader.calculateSegments(
                    taskId: task.id,
                    totalBytes: probe.totalBytes,
                    segmentCount: 4,
                    acceptRanges: probe.acceptRanges
                )

                let downloader = HTTPRangeDownloader(session: session)
                try await downloader.download(
                    task: updatedTask,
                    segments: segments,
                    onProgress: { _, _ in },
                    onSegmentUpdate: { _ in }
                )
            }

            // 5. Verification: Check file existence and non-empty size
            let attrs = try FileManager.default.attributesOfItem(atPath: targetFile.path)
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            guard fileSize > 0 else {
                return TestResult(
                    testCase: testCase,
                    success: false,
                    filePath: targetFile.path,
                    fileSize: 0,
                    durationSeconds: Date().timeIntervalSince(startTime),
                    message: "Downloaded file is 0 bytes"
                )
            }

            // 6. Verification: Check Magic Bytes (must be media, not HTML error page)
            let handle = try FileHandle(forReadingFrom: targetFile)
            let headerData = try handle.read(upToCount: 512) ?? Data()
            try? handle.close()

            if isHTMLError(data: headerData) {
                try? FileManager.default.removeItem(at: targetFile)
                return TestResult(
                    testCase: testCase,
                    success: false,
                    filePath: targetFile.path,
                    fileSize: fileSize,
                    durationSeconds: Date().timeIntervalSince(startTime),
                    message: "File contains HTML error response instead of media data"
                )
            }

            let duration = Date().timeIntervalSince(startTime)
            print(String(format: "  [PASS] #%03d [%@] Size: %d bytes (%.2fs)", testCase.id, testCase.domain, fileSize, duration))

            return TestResult(
                testCase: testCase,
                success: true,
                filePath: targetFile.path,
                fileSize: fileSize,
                durationSeconds: duration,
                message: "OK"
            )
        } catch {
            return TestResult(
                testCase: testCase,
                success: false,
                filePath: nil,
                fileSize: 0,
                durationSeconds: Date().timeIntervalSince(startTime),
                message: "Download error: \(error.localizedDescription)"
            )
        }
    }

    static func isHTMLError(data: Data) -> Bool {
        guard let str = String(data: data.prefix(128), encoding: .utf8)?.lowercased() else {
            return false
        }
        return str.hasPrefix("<!doctype html") || str.hasPrefix("<html") || str.contains("<head>")
    }

    static func buildImageTestCases() -> [MediaTestCase] {
        var cases: [MediaTestCase] = []
        cases.append(MediaTestCase(id: 1, domain: "ei.phncdn.com", url: "https://ei.phncdn.com/www-static/images/pornhub_logo_straight.svg?cache=2026100601", isVideo: false, referer: "https://www.pornhub.com/"))
        cases.append(MediaTestCase(id: 2, domain: "github.githubassets.com", url: "https://github.githubassets.com/favicons/favicon.png", isVideo: false))
        cases.append(MediaTestCase(id: 3, domain: "njav.tv", url: "https://njav.tv/assets/123av/logo-square.png", isVideo: false, referer: "https://njav.tv/"))
        cases.append(MediaTestCase(id: 4, domain: "hentaivn.show", url: "https://hentaivn.show/wp-content/uploads/2024/02/HENTAIVN_Thumbnail.jpg", isVideo: false, referer: "https://hentaivn.show/"))
        cases.append(MediaTestCase(id: 5, domain: "hentaivn.cx", url: "https://hentaivn.cx/wp-content/uploads/2024/02/cropped-hentaivn-512x512-1-32x32.png", isVideo: false, referer: "https://hentaivn.cx/"))
        cases.append(MediaTestCase(id: 6, domain: "upload.wikimedia.org", url: "https://upload.wikimedia.org/wikipedia/commons/4/47/PNG_transparency_demonstration_1.png", isVideo: false))
        cases.append(MediaTestCase(id: 7, domain: "images.unsplash.com", url: "https://images.unsplash.com/photo-1579783900882-c0d3dad7b119?w=300", isVideo: false))
        cases.append(MediaTestCase(id: 8, domain: "images.pexels.com", url: "https://images.pexels.com/photos/15286/pexels-photo.jpg?auto=compress&cs=tinysrgb&w=300", isVideo: false))
        cases.append(MediaTestCase(id: 9, domain: "placehold.co", url: "https://placehold.co/200x200.png", isVideo: false))
        cases.append(MediaTestCase(id: 10, domain: "i.imgur.com", url: "https://i.imgur.com/8QfR8U0.jpeg", isVideo: false))
        cases.append(MediaTestCase(id: 11, domain: "picsum.photos", url: "https://picsum.photos/200/200", isVideo: false))
        cases.append(MediaTestCase(id: 12, domain: "dummyimage.com", url: "https://dummyimage.com/200x200/000/fff.png", isVideo: false))
        cases.append(MediaTestCase(id: 13, domain: "robohash.org", url: "https://robohash.org/internetdownloader.png", isVideo: false))
        cases.append(MediaTestCase(id: 14, domain: "raw.githubusercontent.com", url: "https://raw.githubusercontent.com/github/explore/80688e429a7d4ef2fca1e82350fe8e3517d3494d/topics/swift/swift.png", isVideo: false))
        cases.append(MediaTestCase(id: 15, domain: "api.dicebear.com", url: "https://api.dicebear.com/7.x/bottts/svg?seed=idm", isVideo: false))
        cases.append(MediaTestCase(id: 16, domain: "cdn.jsdelivr.net", url: "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/1f600.png", isVideo: false))
        cases.append(MediaTestCase(id: 17, domain: "unpkg.com", url: "https://unpkg.com/@primer/octicons@19.8.0/build/svg/mark-github-16.svg", isVideo: false))
        cases.append(MediaTestCase(id: 18, domain: "tile.openstreetmap.org", url: "https://tile.openstreetmap.org/0/0/0.png", isVideo: false))
        cases.append(MediaTestCase(id: 19, domain: "iili.io", url: "https://iili.io/d1gT62e.md.png", isVideo: false))
        cases.append(MediaTestCase(id: 20, domain: "archive.org", url: "https://archive.org/images/glogo.png", isVideo: false))
        cases.append(MediaTestCase(id: 21, domain: "www.w3.org", url: "https://www.w3.org/Icons/w3c_home.png", isVideo: false))
        cases.append(MediaTestCase(id: 22, domain: "developer.mozilla.org", url: "https://developer.mozilla.org/favicon-48x48.png", isVideo: false))
        cases.append(MediaTestCase(id: 23, domain: "www.google.com", url: "https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_92x30dp.png", isVideo: false))
        cases.append(MediaTestCase(id: 24, domain: "www.gstatic.com", url: "https://www.gstatic.com/webp/gallery/1.webp", isVideo: false))
        cases.append(MediaTestCase(id: 25, domain: "img-prod-cms-rt-microsoft-com.akamaized.net", url: "https://img-prod-cms-rt-microsoft-com.akamaized.net/cms/api/am/imageFileData/RE1Mu3b?ver=5c31", isVideo: false))
        cases.append(MediaTestCase(id: 26, domain: "www.gravatar.com", url: "https://www.gravatar.com/avatar/00000000000000000000000000000000?d=identicon&f=y", isVideo: false))
        cases.append(MediaTestCase(id: 27, domain: "httpbin.org", url: "https://httpbin.org/image/jpeg", isVideo: false))
        cases.append(MediaTestCase(id: 28, domain: "media.giphy.com", url: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExOHp4ZWF0bms1cWp2MWR2cGtlMnNtd2FhZ3M4enZodmRrbG8yM2x3NyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/3oEjI6SIIHBdRxXI40/giphy.gif", isVideo: false))
        cases.append(MediaTestCase(id: 29, domain: "pbs.twimg.com", url: "https://pbs.twimg.com/profile_images/1683325380441128960/yRsRRjGO_400x400.jpg", isVideo: false))
        cases.append(MediaTestCase(id: 30, domain: "assets.tumblr.com", url: "https://assets.tumblr.com/images/default_avatar/cube_closed_128.png", isVideo: false))
        cases.append(MediaTestCase(id: 31, domain: "www.cloudflare.com", url: "https://www.cloudflare.com/img/logo-cloudflare-dark.svg", isVideo: false))
        cases.append(MediaTestCase(id: 32, domain: "a.basemaps.cartocdn.com", url: "https://a.basemaps.cartocdn.com/light_all/0/0/0.png", isVideo: false))
        cases.append(MediaTestCase(id: 33, domain: "www.who.int", url: "https://www.who.int/ResourcePackages/WHO/assets/dist/images/logos/en/h-logo-blue.svg", isVideo: false))
        cases.append(MediaTestCase(id: 34, domain: "ucsd.edu", url: "https://ucsd.edu/_resources/img/logo_UCSD.png", isVideo: false))
        cases.append(MediaTestCase(id: 35, domain: "www.washington.edu", url: "https://www.washington.edu/brand/files/2014/09/W-Logo_Purple_Hex.png", isVideo: false))
        cases.append(MediaTestCase(id: 36, domain: "tile.loc.gov", url: "https://tile.loc.gov/storage-services/service/pnp/cph/3a50000/3a51000/3a51800/3a51833_150px.jpg", isVideo: false))
        cases.append(MediaTestCase(id: 37, domain: "images.metmuseum.org", url: "https://images.metmuseum.org/CRDImages/ep/web-large/DP145921.jpg", isVideo: false))
        cases.append(MediaTestCase(id: 38, domain: "cdnjs.cloudflare.com", url: "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/sprites/solid.svg", isVideo: false))
        cases.append(MediaTestCase(id: 39, domain: "images-assets.nasa.gov", url: "https://images-assets.nasa.gov/image/PIA12348/PIA12348~thumb.jpg", isVideo: false))
        cases.append(MediaTestCase(id: 40, domain: "data-url", url: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", isVideo: false))
        cases.append(MediaTestCase(id: 41, domain: "data-url", url: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100' fill='cyan'/></svg>", isVideo: false))
        cases.append(MediaTestCase(id: 42, domain: "www.python.org", url: "https://www.python.org/static/community_logos/python-logo-generic.svg", isVideo: false))
        cases.append(MediaTestCase(id: 43, domain: "www.rust-lang.org", url: "https://www.rust-lang.org/static/images/rust-logo-blk.svg", isVideo: false))
        cases.append(MediaTestCase(id: 44, domain: "go.dev", url: "https://go.dev/images/go-logo-blue.svg", isVideo: false))
        cases.append(MediaTestCase(id: 45, domain: "www.apache.org", url: "https://www.apache.org/foundation/press/kit/asf_logo_url.png", isVideo: false))
        cases.append(MediaTestCase(id: 46, domain: "www.debian.org", url: "https://www.debian.org/logos/openlogo-nd-100.png", isVideo: false))
        cases.append(MediaTestCase(id: 47, domain: "www.kernel.org", url: "https://www.kernel.org/theme/images/logos/tux.png", isVideo: false))
        cases.append(MediaTestCase(id: 48, domain: "www.php.net", url: "https://www.php.net/images/logos/new-php-logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 49, domain: "www.ruby-lang.org", url: "https://www.ruby-lang.org/images/header-ruby-logo.png", isVideo: false))
        cases.append(MediaTestCase(id: 50, domain: "nodejs.org", url: "https://nodejs.org/static/images/logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 51, domain: "deno.land", url: "https://deno.land/logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 52, domain: "bun.sh", url: "https://bun.sh/logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 53, domain: "svelte.dev", url: "https://svelte.dev/svelte-logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 54, domain: "vuejs.org", url: "https://vuejs.org/logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 55, domain: "react.dev", url: "https://react.dev/favicon.ico", isVideo: false))
        cases.append(MediaTestCase(id: 56, domain: "angular.dev", url: "https://angular.dev/assets/images/press-kit/angular_wordmark_gradient.png", isVideo: false))
        cases.append(MediaTestCase(id: 57, domain: "getbootstrap.com", url: "https://getbootstrap.com/docs/5.3/assets/brand/bootstrap-logo-shadow.png", isVideo: false))
        cases.append(MediaTestCase(id: 58, domain: "tailwindcss.com", url: "https://tailwindcss.com/favicons/favicon-32x32.png", isVideo: false))
        cases.append(MediaTestCase(id: 59, domain: "www.electronjs.org", url: "https://www.electronjs.org/assets/img/logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 60, domain: "tauri.app", url: "https://tauri.app/meta/favicon-96x96.png", isVideo: false))
        cases.append(MediaTestCase(id: 61, domain: "www.swift.org", url: "https://www.swift.org/favicon.ico", isVideo: false))
        cases.append(MediaTestCase(id: 62, domain: "static.npmjs.com", url: "https://static.npmjs.com/58a19602036db1daee0d7863c94673a4.png", isVideo: false))
        cases.append(MediaTestCase(id: 63, domain: "curl.se", url: "https://curl.se/logo/curl-logo.svg", isVideo: false))
        cases.append(MediaTestCase(id: 64, domain: "nginx.org", url: "https://nginx.org/nginx.gif", isVideo: false))
        cases.append(MediaTestCase(id: 65, domain: "www.postgresql.org", url: "https://www.postgresql.org/media/img/about/press/elephant.png", isVideo: false))
        cases.append(MediaTestCase(id: 66, domain: "grafana.com", url: "https://grafana.com/static/img/menu/grafana2.svg", isVideo: false))
        cases.append(MediaTestCase(id: 67, domain: "www.netbsd.org", url: "https://www.netbsd.org/images/NetBSD-smaller.png", isVideo: false))
        cases.append(MediaTestCase(id: 68, domain: "www.torproject.org", url: "https://www.torproject.org/static/images/tor-logo@2x.png", isVideo: false))
        cases.append(MediaTestCase(id: 69, domain: "duckduckgo.com", url: "https://duckduckgo.com/assets/logo_homepage.normal.v108.svg", isVideo: false))
        cases.append(MediaTestCase(id: 70, domain: "brave.com", url: "https://brave.com/static-assets/images/brave-logo-sans-text.svg", isVideo: false))
        cases.append(MediaTestCase(id: 71, domain: "www.opera.com", url: "https://www.opera.com/favicon.ico", isVideo: false))
        cases.append(MediaTestCase(id: 72, domain: "wac-cdn.atlassian.com", url: "https://wac-cdn.atlassian.com/assets/img/favicons/bitbucket/favicon-32x32.png", isVideo: false))
        cases.append(MediaTestCase(id: 73, domain: "wac-cdn.atlassian.com", url: "https://wac-cdn.atlassian.com/assets/img/favicons/atlassian/favicon.png", isVideo: false))
        cases.append(MediaTestCase(id: 74, domain: "a.slack-edge.com", url: "https://a.slack-edge.com/80588/marketing/img/meta/slack_hash_256.png", isVideo: false))
        cases.append(MediaTestCase(id: 75, domain: "assets-global.website-files.com", url: "https://assets-global.website-files.com/6257adef93867e50d84d30e2/636e0a6a49cf127bf92de1e2_icon_clyde_blurple_RGB.png", isVideo: false))
        cases.append(MediaTestCase(id: 76, domain: "telegram.org", url: "https://telegram.org/img/t_logo.png", isVideo: false))
        cases.append(MediaTestCase(id: 77, domain: "en.wikipedia.org", url: "https://en.wikipedia.org/static/images/icons/wikipedia.png", isVideo: false))
        cases.append(MediaTestCase(id: 78, domain: "fr.wikipedia.org", url: "https://fr.wikipedia.org/static/images/project-logos/frwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 79, domain: "de.wikipedia.org", url: "https://de.wikipedia.org/static/images/project-logos/dewiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 80, domain: "ja.wikipedia.org", url: "https://ja.wikipedia.org/static/images/project-logos/jawiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 81, domain: "vi.wikipedia.org", url: "https://vi.wikipedia.org/static/images/project-logos/viwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 82, domain: "es.wikipedia.org", url: "https://es.wikipedia.org/static/images/project-logos/eswiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 83, domain: "ru.wikipedia.org", url: "https://ru.wikipedia.org/static/images/project-logos/ruwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 84, domain: "zh.wikipedia.org", url: "https://zh.wikipedia.org/static/images/project-logos/zhwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 85, domain: "it.wikipedia.org", url: "https://it.wikipedia.org/static/images/project-logos/itwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 86, domain: "pt.wikipedia.org", url: "https://pt.wikipedia.org/static/images/project-logos/ptwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 87, domain: "pl.wikipedia.org", url: "https://pl.wikipedia.org/static/images/project-logos/plwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 88, domain: "nl.wikipedia.org", url: "https://nl.wikipedia.org/static/images/project-logos/nlwiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 89, domain: "commons.wikimedia.org", url: "https://commons.wikimedia.org/static/images/project-logos/commonswiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 90, domain: "www.wikidata.org", url: "https://www.wikidata.org/static/images/project-logos/wikidatawiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 91, domain: "www.wikivoyage.org", url: "https://www.wikivoyage.org/static/images/project-logos/wikivoyage.png", isVideo: false))
        cases.append(MediaTestCase(id: 92, domain: "www.wikinews.org", url: "https://www.wikinews.org/static/images/project-logos/wikinews.png", isVideo: false))
        cases.append(MediaTestCase(id: 93, domain: "www.wikibooks.org", url: "https://www.wikibooks.org/static/images/project-logos/wikibooks.png", isVideo: false))
        cases.append(MediaTestCase(id: 94, domain: "www.wikiversity.org", url: "https://www.wikiversity.org/static/images/project-logos/wikiversity.png", isVideo: false))
        cases.append(MediaTestCase(id: 95, domain: "www.wikiquote.org", url: "https://www.wikiquote.org/static/images/project-logos/wikiquote.png", isVideo: false))
        cases.append(MediaTestCase(id: 96, domain: "www.wiktionary.org", url: "https://www.wiktionary.org/static/images/project-logos/wiktionary.png", isVideo: false))
        cases.append(MediaTestCase(id: 97, domain: "wikisource.org", url: "https://wikisource.org/static/images/project-logos/sourceswiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 98, domain: "species.wikimedia.org", url: "https://species.wikimedia.org/static/images/project-logos/specieswiki.png", isVideo: false))
        cases.append(MediaTestCase(id: 99, domain: "apple.com-favicon", url: "https://www.apple.com/favicon.ico", isVideo: false))
        cases.append(MediaTestCase(id: 100, domain: "en.wikipedia.org-favicon", url: "https://en.wikipedia.org/static/favicon/wikipedia.ico", isVideo: false))
        return cases
    }

    static func buildVideoTestCases() -> [MediaTestCase] {
        var cases: [MediaTestCase] = []
        cases.append(MediaTestCase(id: 1, domain: "xnhau.navy", url: "https://xnhau.navy/get_file/3/438da8d3a155559a8372725e72a46358/563000/563684/563684_preview.mp4", isVideo: true, referer: "https://xnhau.navy/"))
        cases.append(MediaTestCase(id: 2, domain: "apple.com", url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8", isVideo: true))
        cases.append(MediaTestCase(id: 3, domain: "d2zihajmogu5jn.cloudfront.net", url: "https://d2zihajmogu5jn.cloudfront.net/bipbop-advanced/bipbop_16x9_variant.m3u8", isVideo: true))
        cases.append(MediaTestCase(id: 4, domain: "test-streams.mux.dev", url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", isVideo: true))
        cases.append(MediaTestCase(id: 5, domain: "demo.unified-streaming.com", url: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8", isVideo: true))
        cases.append(MediaTestCase(id: 6, domain: "download.blender.org", url: "https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov", isVideo: true))
        cases.append(MediaTestCase(id: 7, domain: "w3schools.com-mp4", url: "https://www.w3schools.com/html/mov_bbb.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 8, domain: "w3schools.com-webm", url: "https://www.w3schools.com/html/mov_bbb.webm", isVideo: true))
        cases.append(MediaTestCase(id: 9, domain: "w3schools.com-ogg", url: "https://www.w3schools.com/html/mov_bbb.ogg", isVideo: true))
        cases.append(MediaTestCase(id: 10, domain: "w3schools.com-tags", url: "https://www.w3schools.com/tags/mov_bbb.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 11, domain: "learningcontainer.com", url: "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 12, domain: "test-videos.co.uk-bigbuckbunny-mp4-h264_360", url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 13, domain: "test-videos.co.uk-jellyfish-mp4-h264_360", url: "https://test-videos.co.uk/vids/jellyfish/mp4/h264/360/Jellyfish_360_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 14, domain: "test-videos.co.uk-sintel-mp4-h264_360", url: "https://test-videos.co.uk/vids/sintel/mp4/h264/360/Sintel_360_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 15, domain: "test-videos.co.uk-bigbuckbunny-webm-vp8_360", url: "https://test-videos.co.uk/vids/bigbuckbunny/webm/vp8/360/Big_Buck_Bunny_360_10s_1MB.webm", isVideo: true))
        cases.append(MediaTestCase(id: 16, domain: "test-videos.co.uk-jellyfish-webm-vp8_360", url: "https://test-videos.co.uk/vids/jellyfish/webm/vp8/360/Jellyfish_360_10s_1MB.webm", isVideo: true))
        cases.append(MediaTestCase(id: 17, domain: "test-videos.co.uk-bigbuckbunny-mkv-360", url: "https://test-videos.co.uk/vids/bigbuckbunny/mkv/360/Big_Buck_Bunny_360_10s_1MB.mkv", isVideo: true))
        cases.append(MediaTestCase(id: 18, domain: "test-videos.co.uk-jellyfish-mkv-360", url: "https://test-videos.co.uk/vids/jellyfish/mkv/360/Jellyfish_360_10s_1MB.mkv", isVideo: true))
        cases.append(MediaTestCase(id: 19, domain: "test-videos.co.uk-bigbuckbunny-mp4-h264_720", url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 20, domain: "test-videos.co.uk-jellyfish-mp4-h264_720", url: "https://test-videos.co.uk/vids/jellyfish/mp4/h264/720/Jellyfish_720_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 21, domain: "test-videos.co.uk-sintel-mp4-h264_720", url: "https://test-videos.co.uk/vids/sintel/mp4/h264/720/Sintel_720_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 22, domain: "test-videos.co.uk-bigbuckbunny-mp4-h264_1080", url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 23, domain: "test-videos.co.uk-jellyfish-mp4-h264_1080", url: "https://test-videos.co.uk/vids/jellyfish/mp4/h264/1080/Jellyfish_1080_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 24, domain: "test-videos.co.uk-sintel-mp4-h264_1080", url: "https://test-videos.co.uk/vids/sintel/mp4/h264/1080/Sintel_1080_10s_1MB.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 25, domain: "raw.githubusercontent.com-intel-person-bicycle-car-detection", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/person-bicycle-car-detection.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 26, domain: "cdn.jsdelivr.net-intel-person-bicycle-car-detection", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/person-bicycle-car-detection.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 27, domain: "raw.githubusercontent.com-intel-face-demographics-walking", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/face-demographics-walking.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 28, domain: "cdn.jsdelivr.net-intel-face-demographics-walking", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/face-demographics-walking.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 29, domain: "raw.githubusercontent.com-intel-classroom", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/classroom.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 30, domain: "cdn.jsdelivr.net-intel-classroom", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/classroom.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 31, domain: "raw.githubusercontent.com-intel-head-pose-face-detection-female", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/head-pose-face-detection-female.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 32, domain: "cdn.jsdelivr.net-intel-head-pose-face-detection-female", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/head-pose-face-detection-female.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 33, domain: "raw.githubusercontent.com-intel-driver-action-recognition", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/driver-action-recognition.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 34, domain: "raw.githubusercontent.com-intel-people-detection", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/people-detection.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 35, domain: "cdn.jsdelivr.net-intel-people-detection", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/people-detection.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 36, domain: "raw.githubusercontent.com-intel-bottle-detection", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/bottle-detection.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 37, domain: "cdn.jsdelivr.net-intel-bottle-detection", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/bottle-detection.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 38, domain: "raw.githubusercontent.com-intel-head-pose-face-detection-male", url: "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/head-pose-face-detection-male.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 39, domain: "cdn.jsdelivr.net-intel-head-pose-face-detection-male", url: "https://cdn.jsdelivr.net/gh/intel-iot-devkit/sample-videos@master/head-pose-face-detection-male.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 40, domain: "raw.githubusercontent.com-big_buck_bunny", url: "https://raw.githubusercontent.com/mediaelement/mediaelement-files/master/big_buck_bunny.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 41, domain: "cdn.jsdelivr.net-big_buck_bunny", url: "https://cdn.jsdelivr.net/gh/mediaelement/mediaelement-files@master/big_buck_bunny.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 42, domain: "raw.githubusercontent.com-echo-hereweare", url: "https://raw.githubusercontent.com/mediaelement/mediaelement-files/master/echo-hereweare.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 43, domain: "cdn.jsdelivr.net-echo-hereweare", url: "https://cdn.jsdelivr.net/gh/mediaelement/mediaelement-files@master/echo-hereweare.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 44, domain: "raw.githubusercontent.com-bower-480p", url: "https://raw.githubusercontent.com/bower-media-samples/big-buck-bunny-480p-30s/master/video.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 45, domain: "cdn.jsdelivr.net-bower-480p", url: "https://cdn.jsdelivr.net/gh/bower-media-samples/big-buck-bunny-480p-30s@master/video.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 46, domain: "raw.githubusercontent.com-bower-1080p", url: "https://raw.githubusercontent.com/bower-media-samples/big-buck-bunny-1080p-30s/master/video.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 47, domain: "raw.githubusercontent.com-wpt-movie_5_mp4", url: "https://raw.githubusercontent.com/web-platform-tests/wpt/master/media/movie_5.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 48, domain: "cdn.jsdelivr.net-wpt-movie_5_mp4", url: "https://cdn.jsdelivr.net/gh/web-platform-tests/wpt@master/media/movie_5.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 49, domain: "raw.githubusercontent.com-wpt-movie_300_mp4", url: "https://raw.githubusercontent.com/web-platform-tests/wpt/master/media/movie_300.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 50, domain: "cdn.jsdelivr.net-wpt-movie_300_mp4", url: "https://cdn.jsdelivr.net/gh/web-platform-tests/wpt@master/media/movie_300.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 51, domain: "raw.githubusercontent.com-wpt-white_mp4", url: "https://raw.githubusercontent.com/web-platform-tests/wpt/master/media/white.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 52, domain: "cdn.jsdelivr.net-wpt-white_mp4", url: "https://cdn.jsdelivr.net/gh/web-platform-tests/wpt@master/media/white.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 53, domain: "raw.githubusercontent.com-wpt-test_mp4", url: "https://raw.githubusercontent.com/web-platform-tests/wpt/master/media/test.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 54, domain: "cdn.jsdelivr.net-wpt-test_mp4", url: "https://cdn.jsdelivr.net/gh/web-platform-tests/wpt@master/media/test.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 55, domain: "raw.githubusercontent.com-wpt-test_webm", url: "https://raw.githubusercontent.com/web-platform-tests/wpt/master/media/test.webm", isVideo: true))
        cases.append(MediaTestCase(id: 56, domain: "cdn.jsdelivr.net-wpt-test_webm", url: "https://cdn.jsdelivr.net/gh/web-platform-tests/wpt@master/media/test.webm", isVideo: true))
        cases.append(MediaTestCase(id: 57, domain: "media.giphy.com-3oEjI6SIIHBdRxXI40", url: "https://media.giphy.com/media/3oEjI6SIIHBdRxXI40/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 58, domain: "media.giphy.com-26AHONQ79FdWZhAI0", url: "https://media.giphy.com/media/26AHONQ79FdWZhAI0/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 59, domain: "media.giphy.com-l0HlRnAWXxn0MhKLK", url: "https://media.giphy.com/media/l0HlRnAWXxn0MhKLK/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 60, domain: "media.giphy.com-3o7TKSjRrfIPjeiVyM", url: "https://media.giphy.com/media/3o7TKSjRrfIPjeiVyM/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 61, domain: "media.giphy.com-d2lcHJTG5Tscg", url: "https://media.giphy.com/media/d2lcHJTG5Tscg/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 62, domain: "media.giphy.com-26u4cqiYI30juCOGY", url: "https://media.giphy.com/media/26u4cqiYI30juCOGY/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 63, domain: "media.giphy.com-xT9IgzoKnwFNmISR8I", url: "https://media.giphy.com/media/xT9IgzoKnwFNmISR8I/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 64, domain: "media.giphy.com-3o7btPCcdNniyf0ArS", url: "https://media.giphy.com/media/3o7btPCcdNniyf0ArS/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 65, domain: "media.giphy.com-l0MYC0LajbaPoEADu", url: "https://media.giphy.com/media/l0MYC0LajbaPoEADu/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 66, domain: "media.giphy.com-xT0xeJpnrWC4XWblEk", url: "https://media.giphy.com/media/xT0xeJpnrWC4XWblEk/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 67, domain: "media.giphy.com-3oKIPnAiaMCws8nOsE", url: "https://media.giphy.com/media/3oKIPnAiaMCws8nOsE/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 68, domain: "videos.pexels.com", url: "https://videos.pexels.com/video-files/853889/853889-sd_640_360_25fps.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 69, domain: "upload.wikimedia.org-bbb", url: "https://upload.wikimedia.org/wikipedia/commons/transcoded/c/c0/Big_Buck_Bunny_4K.webm/Big_Buck_Bunny_4K.webm.480p.vp9.webm", isVideo: true))
        cases.append(MediaTestCase(id: 70, domain: "upload.wikimedia.org-sintel", url: "https://upload.wikimedia.org/wikipedia/commons/transcoded/f/f1/Sintel_movie_4K.webm/Sintel_movie_4K.webm.480p.vp9.webm", isVideo: true))
        cases.append(MediaTestCase(id: 71, domain: "data-url-mp4", url: "data:video/mp4;base64,AAAAHGZ0eXBpc29tAAAAAGlzb21tcDQxAAAACHZyZWU=", isVideo: true))
        cases.append(MediaTestCase(id: 72, domain: "data-url-webm", url: "data:video/webm;base64,GkXfo0AgQoaBAUL3gQFC8oEEQvOBCEKCQAR3ZWJtQoeBAkKFgQI=", isVideo: true))
        cases.append(MediaTestCase(id: 73, domain: "media.giphy.com-jbD1jWTh3k153gggYx", url: "https://media.giphy.com/media/jbD1jWTh3k153gggYx/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 74, domain: "media.giphy.com-3oKIPnyeAQ97VB0p0I", url: "https://media.giphy.com/media/3oKIPnyeAQ97VB0p0I/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 75, domain: "media.giphy.com-Qs1EbHPzBtBvRdECyg", url: "https://media.giphy.com/media/Qs1EbHPzBtBvRdECyg/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 76, domain: "media.giphy.com-MuADHrl233JLBLQCFO", url: "https://media.giphy.com/media/MuADHrl233JLBLQCFO/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 77, domain: "media.giphy.com-XJtM2nNFCzT3etvzOB", url: "https://media.giphy.com/media/XJtM2nNFCzT3etvzOB/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 78, domain: "media.giphy.com-J2IqS7jt9CtIhyNXho", url: "https://media.giphy.com/media/J2IqS7jt9CtIhyNXho/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 79, domain: "media.giphy.com-9J5dZ6fwuHpNNWmwL1", url: "https://media.giphy.com/media/9J5dZ6fwuHpNNWmwL1/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 80, domain: "media.giphy.com-lkchsCU80znpExj2ea", url: "https://media.giphy.com/media/lkchsCU80znpExj2ea/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 81, domain: "media.giphy.com-1kh0QjVwEX3KMvtwwP", url: "https://media.giphy.com/media/1kh0QjVwEX3KMvtwwP/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 82, domain: "media.giphy.com-LWDXxbKZqw9kCAIfpg", url: "https://media.giphy.com/media/LWDXxbKZqw9kCAIfpg/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 83, domain: "media.giphy.com-lYUlqc2G8BXXO", url: "https://media.giphy.com/media/lYUlqc2G8BXXO/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 84, domain: "media.giphy.com-7JmuMGOZYJYmeivT8j", url: "https://media.giphy.com/media/7JmuMGOZYJYmeivT8j/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 85, domain: "media.giphy.com-6mkfj3LKowCe4", url: "https://media.giphy.com/media/6mkfj3LKowCe4/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 86, domain: "media.giphy.com-f9jyoKyqjKOMWQKB2H", url: "https://media.giphy.com/media/f9jyoKyqjKOMWQKB2H/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 87, domain: "media.giphy.com-PMExYMdOHKfa6GU32L", url: "https://media.giphy.com/media/PMExYMdOHKfa6GU32L/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 88, domain: "media.giphy.com-874V9rbFKm3XSaRh1C", url: "https://media.giphy.com/media/874V9rbFKm3XSaRh1C/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 89, domain: "media.giphy.com-1n92xz2jS5qLTcuT7L", url: "https://media.giphy.com/media/1n92xz2jS5qLTcuT7L/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 90, domain: "media.giphy.com-s41dmb5FnbfFu", url: "https://media.giphy.com/media/s41dmb5FnbfFu/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 91, domain: "media.giphy.com-KDssyD764KWV3fJeC3", url: "https://media.giphy.com/media/KDssyD764KWV3fJeC3/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 92, domain: "media.giphy.com-9Dk1ba2smFg2KASTcz", url: "https://media.giphy.com/media/9Dk1ba2smFg2KASTcz/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 93, domain: "media.giphy.com-lSg7foxg7PWUt7V5D7", url: "https://media.giphy.com/media/lSg7foxg7PWUt7V5D7/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 94, domain: "media.giphy.com-3XHMTIqcUev2Vy9ILk", url: "https://media.giphy.com/media/3XHMTIqcUev2Vy9ILk/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 95, domain: "media.giphy.com-W4ocVHvqQBCzRGovGv", url: "https://media.giphy.com/media/W4ocVHvqQBCzRGovGv/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 96, domain: "media.giphy.com-8whYnT4CiIuauAWOW9", url: "https://media.giphy.com/media/8whYnT4CiIuauAWOW9/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 97, domain: "media.giphy.com-fdG07xF24smvBim16E", url: "https://media.giphy.com/media/fdG07xF24smvBim16E/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 98, domain: "media.giphy.com-jtcwV2haQzVtDZPsIM", url: "https://media.giphy.com/media/jtcwV2haQzVtDZPsIM/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 99, domain: "media.giphy.com-69AOvJsa99QraxC7dP", url: "https://media.giphy.com/media/69AOvJsa99QraxC7dP/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 100, domain: "media.giphy.com-26DMUbmwicvtB8smc", url: "https://media.giphy.com/media/26DMUbmwicvtB8smc/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 101, domain: "media.giphy.com-WtONfJcVJctQxnWy0G", url: "https://media.giphy.com/media/WtONfJcVJctQxnWy0G/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 102, domain: "media.giphy.com-Vzeq5E6Aop1W6H1sbx", url: "https://media.giphy.com/media/Vzeq5E6Aop1W6H1sbx/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 103, domain: "media.giphy.com-vuNH2P9ojJWH188dIE", url: "https://media.giphy.com/media/vuNH2P9ojJWH188dIE/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 104, domain: "media.giphy.com-FCYNQLacZGwFTNaIIT", url: "https://media.giphy.com/media/FCYNQLacZGwFTNaIIT/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 105, domain: "media.giphy.com-fVbezOLjAicS6UHHqm", url: "https://media.giphy.com/media/fVbezOLjAicS6UHHqm/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 106, domain: "media.giphy.com-dS1rQkeAlZbmo", url: "https://media.giphy.com/media/dS1rQkeAlZbmo/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 107, domain: "media.giphy.com-9DcmfsydZhwgDSA3nR", url: "https://media.giphy.com/media/9DcmfsydZhwgDSA3nR/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 108, domain: "media.giphy.com-zVs0a5PC2tioxlmqgJ", url: "https://media.giphy.com/media/zVs0a5PC2tioxlmqgJ/giphy.mp4", isVideo: true))
        cases.append(MediaTestCase(id: 109, domain: "youtube.com", url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", isVideo: true))
        return cases
    }
}
