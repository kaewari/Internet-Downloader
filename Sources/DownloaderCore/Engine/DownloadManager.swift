import Foundation
import os

private let log = Logger(subsystem: "com.internet-downloader", category: "manager")

public final class DownloadManager: @unchecked Sendable {
    public static let shared = DownloadManager()

    public let store: SQLiteStore
    /// `true` khi store file mở lỗi và manager đang chạy trên in-memory store
    /// fallback (dữ liệu task sẽ mất khi thoát app). Xem A-F1.
    public private(set) var storeInitFailed = false
    public let ipcServer: UnixDomainSocketServer
    // MARK: - TODO (A-F13): tách god-class thành seam Resolve/Probe/Orchestrator/Mux/YtDlp.
    // `queue` concurrent chết đã xóa (grep 1 hit); DownloadManager vẫn là
    // god-class 1700+ dòng — tách dần theo 4 PR, không làm đợt này.

    private var activeDownloaders: [UUID: HTTPRangeDownloader] = [:]
    private var activeHLSTasks: [UUID: HLSDownloader] = [:]
    private var activeProcesses: [UUID: Process] = [:]
    private var activeTaskHandles: [UUID: Task<Void, Never>] = [:]
    private var activeTaskTokens: [UUID: UUID] = [:]
    private let handleLock = NSLock()
    private let slots = DownloadSlots()
    // Non-optional lazy: khởi tạo sau `store`/`slots`, warm-up cuối `init`
    // nên không còn IUO `browserTransfers!` (A-F2).
    private lazy var browserTransfers: BrowserTransfers = BrowserTransfers(
        store: store,
        slots: slots,
        destination: ProcessInfo.processInfo.environment["IDM_DESTINATION"].map { URL(fileURLWithPath: $0) } ?? Self.systemDirectory(.downloadsDirectory),
        notify: { [weak self] in self?.onTasksChanged?() }
    )
    private var taskStrippedCookies = Set<UUID>()
    /// Task đã thử repair audio một lần — tránh vòng lặp tải lại vô hạn.
    private let repairedTaskIdsLock = NSLock()
    private var repairedTaskIds = Set<UUID>()
    private var liveSegments: [UUID: [DownloadSegment]] = [:]
    private var lastDBSaveTime: [UUID: Double] = [:]

    public var onTasksChanged: (@Sendable () -> Void)?
    public var onTaskProgressUpdated: (@Sendable (UUID, Int64, Int64, Int, Int, Double, [DownloadSegment]) -> Void)?
    public var onDownloadStarted: (@Sendable (DownloadTask) -> Void)?
    public var onDownloadCompleted: (@Sendable (DownloadTask) -> Void)?
    public var onDownloadFailed: (@Sendable (DownloadTask) -> Void)?
    public var onDownloadConfirmationRequested: (@Sendable (DownloadTask) -> Void)?

    public init(dbPath: String? = nil) {
        let path: String
        if let customPath = dbPath ?? ProcessInfo.processInfo.environment["IDM_DB_PATH"] {
            path = customPath
        } else {
            let appSupport = Self.systemDirectory(.applicationSupportDirectory)
            let appDir = appSupport.appendingPathComponent("InternetDownloader")
            path = appDir.appendingPathComponent("downloader.sqlite3").path
        }

        do {
            self.store = try SQLiteStore(path: path)
        } catch {
            // A-F1: không crash daemon khi DB file mở lỗi (disk đầy,
            // permission, file hỏng) — fallback sang :memory: và tiếp tục.
            log.error("Could not open SQLiteStore at \(path, privacy: .private): \(error.localizedDescription) — falling back to in-memory store")
            storeInitFailed = true
            // ":memory:" không chạm đĩa nên khởi tạo thành công trong thực tế
            // (chỉ fail khi SQLite runtime/OOM hỏng hoàn toàn — lúc đó không
            // còn cách nào tạo store mà không crash process).
            self.store = try! SQLiteStore(path: ":memory:") // swiftlint:disable:this force_try
        }

        self.ipcServer = UnixDomainSocketServer(socketPath: ProcessInfo.processInfo.environment["IDM_SOCKET_PATH"] ?? UnixDomainSocketServer.defaultSocketPath)
        _ = browserTransfers // warm-up lazy var trên thread init (tránh race khởi tạo lười đa luồng)
        for var task in getAllTasks() where task.status != .completed && task.status != .failed {
            if task.browserInfo != nil {
                task.status = .failed; task.errorMessage = BrowserFailure.reconnect.localizedDescription
                task.browserInfo?.phase = "failed"; task.browserInfo?.errorCode = BrowserFailure.reconnect.rawValue
            } else if task.status == .downloading {
                // Task thường còn .downloading lúc app thoát — worker nào cũng
                // đã chết; dừng để user bấm Tiếp tục (.pending giữ nguyên vì
                // là task chờ xếp hàng hợp lệ).
                task.status = .paused
                task.speed = 0
                task.errorMessage = "Ứng dụng thoát giữa lúc tải — nhấn Tiếp tục để tải lại"
            }
            try? store.saveTask(task)
        }
        setupIPCHandler()
    }

    public func startIPC() {
        do {
            try ipcServer.start()
        } catch {
            log.error("Failed to start IPC Server: \(error.localizedDescription)")
        }
    }

    public func stopIPC() {
        ipcServer.stop()
    }

    private func setupIPCHandler() {
        ipcServer.requestHandler = { [weak self] request in
            guard let self = self else {
                return IPCResponse(success: false, message: "Manager deallocated")
            }

            if request.action.hasPrefix("browser_") { return await self.browserTransfers.command(request) }
            if request.action == "hello" {
                let compatible = request.protocolVersion == AppVersion.protocolVersion
                return IPCResponse(
                    success: compatible,
                    message: compatible ? "Ready" : "App/extension cần cập nhật cùng phiên bản.",
                    extra: [
                        "protocolVersion": "\(AppVersion.protocolVersion)",
                        "appVersion": AppVersion.appVersion,
                        "extensionVersion": AppVersion.extensionVersion,
                        "code": compatible ? "ok" : "protocol_mismatch"
                    ]
                )
            }

            switch request.action {
            case "start_download":
                guard let urlStr = request.url, let url = URLNormalizer.normalize(urlStr) else {
                    let browserSource = request.url?.lowercased().hasPrefix("blob:") == true || URL(string: request.url ?? "")?.host?.lowercased() == "web.telegram.org"
                    return IPCResponse(success: false, message: browserSource ? "Nguồn này cần Save qua Chrome. Chọn lại attachment bằng extension mới." : "Invalid URL",
                        extra: ["code": browserSource ? "browser_source_required" : "invalid_url", "stage": "discovery"])
                }

                let defaultDest = Self.systemDirectory(.downloadsDirectory)
                do {
                    // autoStart = true khi người dùng bật "tự động bắt đầu" trong
                    // extension: tạo task và tải ngay, không chờ hộp thoại xác nhận.
                    let autoStart = request.autoStart == true
                    let confirmation = autoStart ? nil : self.onDownloadConfirmationRequested
                    let dedupWindow: TimeInterval = 5.0

                    if let confirmation {
                        let now = Date()
                        let existingPending = self.getAllTasks().first { existing in
                            guard existing.status == .pending,
                                  existing.downloadedBytes == 0,
                                  now.timeIntervalSince(existing.createdAt) < dedupWindow,
                                  self.handleLock.withLock({ self.activeTaskHandles[existing.id] == nil }) else {
                                return false
                            }
                            if existing.url == url { return true }
                            if let reqRef = request.referrer, !reqRef.isEmpty, existing.url.absoluteString == reqRef {
                                return true
                            }
                            return false
                        }
                        if var existing = existingPending {
                            let incomingName = (request.filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let existingExt = (existing.filename as NSString).pathExtension
                            let existingIsWeak = existing.filename.isEmpty
                                || existing.filename == "download"
                                || FileTypeDetector.isOpaqueIdentifier(existing.filename)
                                || existingExt.isEmpty
                            if !incomingName.isEmpty && incomingName != "download" && !FileTypeDetector.isOpaqueIdentifier(incomingName) && existingIsWeak {
                                existing.filename = incomingName
                            }
                            if existing.url != url {
                                existing.url = url
                            }
                            if let cookies = request.cookies, !cookies.isEmpty, (existing.cookies == nil || existing.cookies?.isEmpty == true) {
                                existing.cookies = cookies
                            }
                            if let headers = request.headers, !headers.isEmpty, (existing.headers == nil || existing.headers?.isEmpty == true) {
                                existing.headers = headers
                            }
                            if let ref = request.referrer, !ref.isEmpty, (existing.referrer == nil || existing.referrer?.isEmpty == true) {
                                existing.referrer = ref
                            }
                            try self.store.saveTask(existing)
                            self.onTasksChanged?()
                            confirmation(existing)
                            return IPCResponse(success: true, taskId: existing.id.uuidString, message: "Awaiting confirmation",
                                extra: ["code": "awaiting_confirmation", "stage": "discovery"])
                        }
                    }

                    let task = try self.createNewTask(
                        url: url,
                        filename: request.filename ?? "",
                        destinationFolder: defaultDest,
                        referrer: request.referrer,
                        userAgent: request.userAgent,
                        cookies: request.cookies,
                        headers: request.headers
                    )
                    if let confirmation {
                        confirmation(task)
                        return IPCResponse(success: true, taskId: task.id.uuidString, message: "Awaiting confirmation",
                            extra: ["code": "awaiting_confirmation", "stage": "discovery"])
                    } else {
                        self.startDownload(taskId: task.id)
                        return IPCResponse(success: true, taskId: task.id.uuidString, message: "Download started",
                            extra: ["code": "started", "stage": "discovery"])
                    }
                } catch {
                    return IPCResponse(success: false, message: error.localizedDescription,
                        extra: ["code": "invalid_url", "stage": "discovery"])
                }

            case "pause_download":
                if let taskIdStr = request.taskId, let id = UUID(uuidString: taskIdStr) {
                    self.pauseDownload(taskId: id)
                    return IPCResponse(success: true, taskId: taskIdStr, message: "Download paused")
                }
                return IPCResponse(success: false, message: "Missing taskId")

            case "resume_download":
                if let taskIdStr = request.taskId, let id = UUID(uuidString: taskIdStr) {
                    self.startDownload(taskId: id)
                    return IPCResponse(success: true, taskId: taskIdStr, message: "Download resumed")
                }
                return IPCResponse(success: false, message: "Missing taskId")

            case "cancel_download":
                if let taskIdStr = request.taskId, let id = UUID(uuidString: taskIdStr) {
                    self.deleteTask(taskId: id)
                    return IPCResponse(success: true, taskId: taskIdStr, message: "Download cancelled")
                }
                return IPCResponse(success: false, message: "Missing taskId")

            case "ping":
                return IPCResponse(success: true, message: "pong")

            default:
                return IPCResponse(success: false, message: "Unknown action: \(request.action)")
            }
        }
    }

    public func getAllTasks() -> [DownloadTask] {
        (try? store.getAllTasks()) ?? []
    }

    public func getTask(id: UUID) -> DownloadTask? {
        try? store.getTask(id: id)
    }

    public func getSegments(for taskId: UUID) -> [DownloadSegment] {
        if let live = handleLock.withLock({ liveSegments[taskId] }), !live.isEmpty {
            return live
        }
        return (try? store.getSegments(for: taskId)) ?? []
    }

    /// Thư mục hệ thống với fallback tmp dir khi lookup fail (A-F2:
    /// thay `.first!` — sandbox/daemon thiếu thư mục chuẩn vẫn chạy tiếp).
    public static func systemDirectory(_ dir: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: dir, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static func categorizedFolder(for filename: String, baseFolder: URL) -> URL {        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let subfolder: String
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "ts", "m3u8":
            subfolder = "Videos"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg":
            subfolder = "Audio"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst":
            subfolder = "Compressed"
        case "dmg", "pkg", "iso", "app", "exe", "msi", "deb", "rpm", "appimage":
            subfolder = "Programs"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "rtf":
            subfolder = "Documents"
        case "sqlite", "db", "json", "xml", "yaml", "yml", "sql", "whl":
            subfolder = "Data"
        case "ttf", "otf", "woff", "woff2":
            subfolder = "Fonts"
        case "jpg", "jpeg", "png", "gif", "webp", "svg":
            subfolder = "Images"
        default:
            return baseFolder
        }

        let target = baseFolder.appendingPathComponent(subfolder)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    public func createNewTask(
        url: URL,
        filename: String = "",
        destinationFolder: URL,
        segmentsCount: Int = 8,
        referrer: String? = nil,
        userAgent: String? = nil,
        cookies: String? = nil,
        headers: [String: String]? = nil
    ) throws -> DownloadTask {
        guard let cleanURL = URLNormalizer.normalize(url.absoluteString) else {
            throw URLError(.badURL)
        }

        var cleanFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanFilename.isEmpty || cleanFilename == "download" || FileTypeDetector.isOpaqueIdentifier(cleanFilename) {
            if let queryFilename = FileTypeDetector.extractFilename(from: cleanURL) {
                cleanFilename = queryFilename
            } else if cleanFilename.isEmpty {
                if DataURLHandler.isDataURL(cleanURL) {
                    let parsed = try? DataURLHandler.parse(urlString: cleanURL.absoluteString)
                    let ext = parsed?.suggestedExtension ?? "bin"
                    cleanFilename = "data_\(UUID().uuidString.prefix(6)).\(ext)"
                } else {
                    cleanFilename = cleanURL.lastPathComponent.isEmpty ? "download" : cleanURL.lastPathComponent
                }
            }
        }
        cleanFilename = FileTypeDetector.sanitizeFilename(cleanFilename)
        // IDM-style collision: không ghi đè file tồn tại — thêm (1), (2)...
        let uniqueName = FileTypeDetector.uniqueDestination(in: destinationFolder, filename: cleanFilename)
        if uniqueName.lastPathComponent != cleanFilename {
            cleanFilename = uniqueName.lastPathComponent
        }

        let task = DownloadTask(
            url: cleanURL,
            filename: cleanFilename,
            destinationFolder: destinationFolder,
            totalBytes: -1,
            downloadedBytes: 0,
            status: .pending,
            segmentsCount: segmentsCount,
            referrer: referrer,
            userAgent: userAgent ?? URLNormalizer.defaultUserAgent,
            cookies: cookies,
            headers: headers
        )

        try store.saveTask(task)
        onTasksChanged?()
        return task
    }

    private func isCancelledOrInactive(_ taskId: UUID) -> Bool {        if Task.isCancelled { return true }
        guard let status = getTask(id: taskId)?.status else { return true }
        return status == .paused
    }

    private func flushLiveSegmentsToStore(taskId: UUID) {
        let finalSegments = handleLock.withLock {
            _ = activeDownloaders.removeValue(forKey: taskId)
            _ = lastDBSaveTime.removeValue(forKey: taskId)
            return liveSegments.removeValue(forKey: taskId) ?? []
        }
        guard !finalSegments.isEmpty, var existingTask = try? store.getTask(id: taskId) else { return }
        var segs = finalSegments
        var sumDownloaded: Int64 = 0
        for i in 0..<segs.count {
            if segs[i].status == .downloading {
                segs[i].status = .paused
            }
            sumDownloaded += segs[i].downloadedBytes
        }
        try? store.saveSegments(segs)
        if sumDownloaded > existingTask.downloadedBytes {
            existingTask.downloadedBytes = sumDownloaded
            try? store.saveTask(existingTask)
        }
    }

    /// Cổng kiểm tra kích thước sau khi tải xong.
    ///
    /// Khi server khai báo `totalBytes`, kích thước file trên đĩa phải khớp —
    /// nếu không, mạng đã rớt dữ liệu và task **không** được coi là hoàn tất.
    /// - Returns: thông báo lỗi nếu có vấn đề, `nil` nếu hợp lệ.
    public static func completionSizeGate(task: DownloadTask, fileURL: URL) -> String? {
        guard task.totalBytes > 0 else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let realSize = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        guard realSize != task.totalBytes else { return nil }
        return "Kích thước tệp không khớp (thực tế \(realSize) / kỳ vọng \(task.totalBytes)) — nhấn Tiếp tục để tải lại"
    }

    public func startDownload(taskId: UUID) {
        guard let task = getTask(id: taskId) else { return }
        if task.browserInfo != nil || URLNormalizer.normalize(task.url.absoluteString) == nil {
            var failed = task; failed.status = .failed; failed.errorMessage = BrowserFailure.reconnect.localizedDescription
            try? store.saveTask(failed); onTasksChanged?(); return
        }

        let token = UUID()
        let previous = handleLock.withLock {
            let prev = activeTaskHandles[taskId]
            activeTaskTokens[taskId] = token
            return prev
        }
        previous?.cancel()
        var pending = task; pending.status = .pending; pending.errorMessage = nil
        try? store.saveTask(pending); onTasksChanged?()

        let handle = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.handleLock.withLock {
                    if self.activeTaskTokens[taskId] == token {
                        self.activeTaskHandles.removeValue(forKey: taskId)
                        self.activeTaskTokens.removeValue(forKey: taskId)
                    }
                }
            }
            await previous?.value
            if Task.isCancelled { return }
            guard var latestPending = self.getTask(id: taskId), latestPending.status != .paused else { return }
            if latestPending.status != .pending {
                latestPending.status = .pending
                latestPending.errorMessage = nil
                try? self.store.saveTask(latestPending)
                self.onTasksChanged?()
            }
            do {
                try await self.slots.acquire(taskId)
                if self.isCancelledOrInactive(taskId) {
                    await self.slots.release(taskId)
                    return
                }
                guard let latestTask = self.getTask(id: taskId) else {
                    await self.slots.release(taskId)
                    return
                }
                self.onDownloadStarted?(latestTask)
                await self.executeDownload(task: latestTask)
                await self.slots.release(taskId)
            } catch { /* A cancelled queued job never starts transport. */ }
        }
        handleLock.withLock { activeTaskHandles[taskId] = handle }
    }

    private func executeDownload(task: DownloadTask) async {
        if isCancelledOrInactive(task.id) { return }
        var currentTask = task
        currentTask.status = .downloading
        currentTask.errorMessage = nil
        try? store.saveTask(currentTask)
        onTasksChanged?()

        // 1. Check if Data URL
        if DataURLHandler.isDataURL(currentTask.url) {
            do {
                let downloader = HTTPRangeDownloader()
                handleLock.withLock { activeDownloaders[currentTask.id] = downloader }
                let taskId = currentTask.id
                try await downloader.download(
                    task: currentTask,
                    segments: [],
                    onProgress: { [weak self] downloaded, _ in
                        guard let self = self else { return }
                        if var t = try? self.store.getTask(id: taskId), t.status != .paused {
                            t.downloadedBytes = downloaded
                            t.totalBytes = downloaded
                            try? self.store.saveTask(t)
                        }
                    },
                    onSegmentUpdate: { _ in }
                )
                if !Task.isCancelled, var completed = try? store.getTask(id: currentTask.id), completed.status != .paused {
                    completed.status = .completed
                    completed.speed = 0
                    if completed.downloadedBytes > 0 {
                        completed.totalBytes = completed.downloadedBytes
                    }
                    try? store.saveTask(completed)
                    onDownloadCompleted?(completed)
                }
                _ = handleLock.withLock { activeDownloaders.removeValue(forKey: currentTask.id) }
                onTasksChanged?()
                return
            } catch {
                if !(error is CancellationError), !Task.isCancelled, var failed = try? store.getTask(id: currentTask.id), failed.status != .paused {
                    failed.status = .failed
                    failed.errorMessage = error.localizedDescription
                    try? store.saveTask(failed)
                }
                _ = handleLock.withLock { activeDownloaders.removeValue(forKey: currentTask.id) }
                onTasksChanged?()
                return
            }
        }

        // 2. Resolve media URL if it is a media platform or page URL
        var effectiveHeaders = currentTask.headers ?? [:]
        if let ref = currentTask.referrer, effectiveHeaders["Referer"] == nil {
            effectiveHeaders["Referer"] = ref
        }

        var resolvedMedia: ResolvedMedia?
        if !MediaURLResolver.isDirectMediaURL(currentTask.url) {
            let resolved = await MediaURLResolver.resolve(
                url: currentTask.url,
                customHeaders: effectiveHeaders.isEmpty ? nil : effectiveHeaders,
                userAgent: currentTask.userAgent,
                cookies: currentTask.cookies
            )
            if isCancelledOrInactive(currentTask.id) { return }
            if resolved.extractor == "unsupported_bare_home" || URLNormalizer.isBarePlatformHomeURL(resolved.directURL) {
                let host = currentTask.url.host ?? "trang chủ"
                if !Task.isCancelled, var failedTask = try? store.getTask(id: currentTask.id), failedTask.status != .paused {
                    failedTask.status = .failed
                    failedTask.errorMessage = "Liên kết là trang chủ hoặc bảng tin (\(host)), không chứa ID video cụ thể. Vui lòng mở bài viết hoặc video cụ thể để tải."
                    failedTask.speed = 0
                    try? store.saveTask(failedTask)
                }
                onTasksChanged?()
                return
            }
            if resolved.directURL != currentTask.url {
                currentTask.url = resolved.directURL
                // Tên file lấy từ URL trang thường là slug vô nghĩa ("watch", "reel")
                // và không có đuôi → dùng tiêu đề thật do trình giải trích trả về.
                let currentExt = (currentTask.filename as NSString).pathExtension
                let shouldUseResolvedName = currentTask.filename == "download"
                    || currentTask.filename.isEmpty
                    || currentExt.isEmpty
                    || FileTypeDetector.isOpaqueIdentifier(currentTask.filename)
                if shouldUseResolvedName, let title = resolved.title, !title.isEmpty {
                    currentTask.filename = resolved.suggestedFilename ?? "\(title).mp4"
                }
                if let ref = resolved.headers["Referer"], currentTask.referrer == nil {
                    currentTask.referrer = ref
                    effectiveHeaders["Referer"] = ref
                }
                if let ua = resolved.headers["User-Agent"], currentTask.userAgent == nil {
                    currentTask.userAgent = ua
                }
                if let newHost = resolved.directURL.host, let oldHost = task.url.host,
                   !URLNormalizer.isSameSiteDomain(newHost, oldHost) {
                    // Chỉ bỏ cookie khi sang site KHÁC hẳn (không gửi cookie sang
                    // domain không liên quan); subdomain của cùng site vẫn giữ.
                    currentTask.cookies = nil
                }
                try? store.saveTask(currentTask)
            }
            resolvedMedia = resolved
        }

        if isCancelledOrInactive(currentTask.id) { return }

        // 2b. Nguồn DASH (YouTube, Bilibili…) tách video và âm thanh thành hai file.
        // Nếu chỉ tải video thì file ra **không có tiếng** → phải ghép bằng ffmpeg.
        if let resolvedMedia, resolvedMedia.requiresMux {
            await executeMuxedDownload(task: currentTask, originalURL: task.url, resolved: resolvedMedia, customHeaders: effectiveHeaders)
            return
        }

        // 3. Check if MPEG-DASH (.mpd) stream — chỉ theo pathExtension thực,
        // không so contains trên absoluteString (query chứa ".mpd" gây fail ảo).
        let isDASH = currentTask.url.pathExtension.lowercased() == "mpd"
        if isDASH {
            if let ytdlp = MediaURLResolver.findYtDlpBinary() {
                do {
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: currentTask, declaredAudio: resolvedMedia?.declaredAudio)
                    return
                } catch {
                    if error is CancellationError || isCancelledOrInactive(currentTask.id) {
                        onTasksChanged?()
                        return
                    }
                    // Fall back to standard range probe if yt-dlp fails
                }
            } else {
                // Không có yt-dlp thì tải manifest chỉ ra file XML, không phải video.
                // Báo rõ thay vì tạo ra file .mpd rác.
                if !Task.isCancelled, var failedTask = try? store.getTask(id: currentTask.id), failedTask.status != .paused {
                    failedTask.status = .failed
                    failedTask.errorMessage = "Nguồn dùng MPEG-DASH (.mpd) — cần yt-dlp để tải video. Cài yt-dlp rồi thử lại."
                    failedTask.speed = 0
                    try? store.saveTask(failedTask)
                    onDownloadFailed?(failedTask)
                }
                onTasksChanged?()
                return
            }
        }

        // 4. Check if HLS stream (.m3u8) — chỉ theo pathExtension thực
        if currentTask.url.pathExtension.lowercased() == "m3u8" {
            await executeHLSDownload(task: currentTask, customHeaders: effectiveHeaders.isEmpty ? nil : effectiveHeaders)
            return
        }

        // 5. Standard HTTP / HTTPS Range Download
        do {
            let probe = try await HTTPRangeDownloader.probeURL(
                url: currentTask.url,
                customHeaders: effectiveHeaders.isEmpty ? nil : effectiveHeaders,
                cookies: currentTask.cookies,
                userAgent: currentTask.userAgent
            )

            if isCancelledOrInactive(currentTask.id) { return }

            currentTask.totalBytes = probe.totalBytes
            currentTask.acceptRanges = probe.acceptRanges
            currentTask.etag = probe.etag
            currentTask.lastModified = probe.lastModified
            if let suggested = probe.suggestedFilename, !suggested.isEmpty {
                let currentExt = (currentTask.filename as NSString).pathExtension
                let suggestedExt = (suggested as NSString).pathExtension
                let shouldReplace = currentTask.filename == "download"
                    || currentTask.filename.isEmpty
                    || FileTypeDetector.isOpaqueIdentifier(currentTask.filename)
                    || (currentExt.isEmpty && !suggestedExt.isEmpty)

                if shouldReplace {
                    currentTask.filename = suggested
                }
            }
            try store.saveTask(currentTask)

            // Check if segments already exist in DB (for resume)
            var segments = (try? store.getSegments(for: currentTask.id)) ?? []
            if segments.isEmpty {
                segments = HTTPRangeDownloader.calculateSegments(
                    taskId: currentTask.id,
                    totalBytes: currentTask.totalBytes,
                    segmentCount: currentTask.segmentsCount,
                    acceptRanges: currentTask.acceptRanges
                )
                try store.saveSegments(segments)
            }

            let taskId = currentTask.id
            let initialTotalBytes = currentTask.totalBytes
            let downloader = HTTPRangeDownloader()
            handleLock.withLock {
                activeDownloaders[taskId] = downloader
                liveSegments[taskId] = segments
            }

            try await downloader.download(
                task: currentTask,
                segments: segments,
                onProgress: { [weak self] downloadedBytes, speed in
                    guard let self = self else { return }
                    if (try? self.store.getTask(id: taskId))?.status == .paused { return }
                    let currentSegments = self.handleLock.withLock { self.liveSegments[taskId] ?? [] }
                    let completedCount = currentSegments.filter { $0.status == .completed }.count
                    let totalBytes = (try? self.store.getTask(id: taskId))?.totalBytes ?? initialTotalBytes

                    let now = Date().timeIntervalSince1970
                    let lastSave = self.handleLock.withLock { self.lastDBSaveTime[taskId] ?? 0 }
                    if now - lastSave >= 1.0 || (completedCount == currentSegments.count && !currentSegments.isEmpty) {
                        self.handleLock.withLock { self.lastDBSaveTime[taskId] = now }
                        if var t = try? self.store.getTask(id: taskId), t.status != .paused {
                            t.downloadedBytes = max(t.downloadedBytes, downloadedBytes)
                            t.speed = speed
                            t.downloadedSegmentsCount = completedCount
                            t.segmentsCount = currentSegments.count
                            try? self.store.saveTask(t)
                        }
                        if !currentSegments.isEmpty {
                            try? self.store.saveSegments(currentSegments)
                        }
                    }

                    self.onTaskProgressUpdated?(taskId, downloadedBytes, totalBytes, completedCount, currentSegments.count, speed, currentSegments)
                },
                onSegmentUpdate: { [weak self] updatedSeg in
                    guard let self = self else { return }
                    self.handleLock.withLock {
                        if var segs = self.liveSegments[taskId], let idx = segs.firstIndex(where: { $0.id == updatedSeg.id }) {
                            segs[idx] = updatedSeg
                            self.liveSegments[taskId] = segs
                        }
                    }
                },
                // A-F11: re-probe đổi totalBytes/etag/segments → đồng bộ DB ngay
                // (không thì completionSizeGate so với totalBytes cũ sẽ fail sai).
                onReprobe: { [weak self] probe in
                    guard let self = self else { return }
                    if var t = try? self.store.getTask(id: taskId), t.status != .paused {
                        t.totalBytes = probe.totalBytes
                        t.acceptRanges = probe.acceptRanges
                        t.etag = probe.etag
                        t.lastModified = probe.lastModified
                        t.downloadedBytes = 0
                        try? self.store.saveTask(t)
                    }
                    let fresh = HTTPRangeDownloader.calculateSegments(
                        taskId: taskId,
                        totalBytes: probe.totalBytes,
                        segmentCount: max(1, self.handleLock.withLock({ self.liveSegments[taskId]?.count }) ?? 1),
                        acceptRanges: probe.acceptRanges
                    )
                    self.handleLock.withLock {
                        self.liveSegments[taskId] = fresh
                        self.lastDBSaveTime[taskId] = Date().timeIntervalSince1970
                    }
                    try? self.store.saveSegments(fresh)
                }
            )

            if !Task.isCancelled, var completedTask = try? store.getTask(id: taskId), completedTask.status == .downloading {
                // Completion size gate: kích thước file trên disk phải khớp
                // totalBytes (khi server khai báo) — không tin byte đếm được,
                // mạng rớt cuối chuỗi không được coi là completed.
                if let sizeProblem = Self.completionSizeGate(task: completedTask, fileURL: completedTask.finalFilePath) {
                    completedTask.status = .failed
                    completedTask.speed = 0
                    completedTask.errorMessage = sizeProblem
                    try? store.saveTask(completedTask)
                    onDownloadFailed?(completedTask)
                    onTasksChanged?()
                    return
                }

                // Cổng kiểm chứng tiếng: không bao giờ báo "hoàn tất" cho file
                // video không có audio khi nguồn được biết là có tiếng.
                completedTask = await finalizeMediaTask(
                    completedTask,
                    fileURL: completedTask.finalFilePath,
                    declaredAudio: resolvedMedia?.declaredAudio,
                    allowRepair: true
                )
                if completedTask.status == .failed {
                    try? store.saveTask(completedTask)
                    onDownloadFailed?(completedTask)
                    onTasksChanged?()
                    return
                }

                completedTask.status = .completed
                completedTask.speed = 0
                if completedTask.totalBytes > 0 {
                    completedTask.downloadedBytes = completedTask.totalBytes
                } else if completedTask.downloadedBytes > 0 {
                    completedTask.totalBytes = completedTask.downloadedBytes
                }

                // Post-download magic bytes inspection: Ensure proper extension in the same destinationFolder
                let targetFile = completedTask.finalFilePath
                let currentExt = (completedTask.filename as NSString).pathExtension
                // Đuôi rỗng, tên dạng mã ẩn, HOẶC đuôi không hợp lệ (URL kiểu
                // `.../format=h.264`) → sửa lại theo magic byte thật của file.
                let extUnknown = !currentExt.isEmpty && !FileTypeDetector.knownExtensions.contains(currentExt.lowercased())
                if currentExt.isEmpty || extUnknown || FileTypeDetector.isOpaqueIdentifier(completedTask.filename) {
                    if let detectedExt = FileTypeDetector.detectExtension(fileURL: targetFile),
                       detectedExt.lowercased() != currentExt.lowercased() {
                        let baseName = (completedTask.filename as NSString).deletingPathExtension
                        let newFilename = currentExt.isEmpty ? "\(completedTask.filename).\(detectedExt)" : "\(baseName).\(detectedExt)"
                        let newFilePath = completedTask.destinationFolder.appendingPathComponent(newFilename)
                        if newFilePath != targetFile {
                            try? FileManager.default.moveItem(at: targetFile, to: newFilePath)
                            completedTask.filename = newFilename
                        }
                    }
                }

                let finalSegments = handleLock.withLock {
                    _ = activeDownloaders.removeValue(forKey: taskId)
                    _ = lastDBSaveTime.removeValue(forKey: taskId)
                    return liveSegments.removeValue(forKey: taskId) ?? []
                }
                try store.saveTask(completedTask)
                if !finalSegments.isEmpty {
                    try? store.saveSegments(finalSegments)
                }
                onDownloadCompleted?(completedTask)
            } else {
                flushLiveSegmentsToStore(taskId: taskId)
            }
            onTasksChanged?()
        } catch {
            let taskId = currentTask.id
            flushLiveSegmentsToStore(taskId: taskId)
            let isURLCancelled = (error as? URLError)?.code == .cancelled
            if error is CancellationError || isURLCancelled || isCancelledOrInactive(taskId) {
                onTasksChanged?()
                return
            }
            var finalError = error
            let ext = currentTask.url.pathExtension.lowercased()
            let isMediaCandidate = [
                "mp4", "mkv", "avi", "mov", "webm", "flv", "ts", "m3u8", "mpd",
                "mp3", "wav", "flac", "aac", "m4a", "ogg"
            ].contains(ext) || (URLNormalizer.isVideoPlatformURL(currentTask.url) && !URLNormalizer.isBarePlatformHomeURL(currentTask.url))

            if isMediaCandidate, let ytdlp = MediaURLResolver.findYtDlpBinary(), !isCancelledOrInactive(taskId) {
                // Phải trả về URL TRANG gốc: URL media đã resolve thường bị CDN
                // chặn (403) và yt-dlp cần URL trang để tự trích xuất đúng.
                var fallbackTask = currentTask
                if fallbackTask.url != task.url, URLNormalizer.isVideoPlatformURL(task.url) {
                    fallbackTask.url = task.url
                }
                do {
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: fallbackTask, declaredAudio: nil)
                    return
                } catch {
                    let isSubCancelled = (error as? URLError)?.code == .cancelled
                    if error is CancellationError || isSubCancelled || isCancelledOrInactive(taskId) {
                        onTasksChanged?()
                        return
                    }
                    finalError = error
                }
            }
            if !Task.isCancelled, var failedTask = try? store.getTask(id: taskId), failedTask.status != .paused {
                failedTask.status = .failed
                failedTask.errorMessage = finalError.localizedDescription
                failedTask.speed = 0
                try? store.saveTask(failedTask)
                onDownloadFailed?(failedTask)
            }
            onTasksChanged?()
        }
    }

    // MARK: - Cổng kiểm chứng âm thanh

    /// Xác minh file media có luồng tiếng; nếu thiếu thì thử repair hoặc đánh
    /// dấu thất bại rõ ràng. Trả về task đã cập nhật (có thể `status == .failed`).
    ///
    /// Lý do tồn tại: trước đây app chỉ kiểm kích thước rồi `completed`, nên file
    /// video-only (DASH/HLS tách audio, yt-dlp thiếu ffmpeg, URL video-only từ
    /// sniffer) vẫn được báo "thành công" — người dùng mở ra mới biết mất tiếng.
    func finalizeMediaTask(
        _ task: DownloadTask,
        fileURL: URL,
        declaredAudio: Bool?,
        allowRepair: Bool
    ) async -> DownloadTask {
        var result = task
        guard MediaIntegrity.isLikelyVideoContainer(fileURL) else { return result }
        guard let report = MediaIntegrity.report(of: fileURL) else {
            result.audioState = .unchecked
            log.warning("Không kiểm tra được luồng media của \(fileURL.lastPathComponent) (thiếu ffprobe?)")
            return result
        }
        if report.hasAudio {
            // Video task mà file chỉ có tiếng (yt-dlp để lại nhầm nhánh audio) thì
            // cũng không được coi là thành công.
            let ext = fileURL.pathExtension.lowercased()
            let audioOnlyExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
            if !report.hasVideo && !audioOnlyExtensions.contains(ext) {
                result.status = .failed
                result.speed = 0
                result.errorMessage = "Tệp tải về chỉ có âm thanh, thiếu luồng hình — thử tải lại bằng yt-dlp."
                return result
            }
            result.audioState = .verified
            return result
        }
        if allowRepair, await repairAudio(task: result, videoFile: fileURL) {
            result.audioState = .repaired
            return result
        }
        if declaredAudio == true {
            result.status = .failed
            result.speed = 0
            result.audioState = .missingInSource
            result.errorMessage = "Video không có tiếng và không ghép được audio từ nguồn. Nhấn \"Tải lại bằng yt-dlp\" để thử lại."
        } else {
            // Nguồn không khai báo audio (hoặc link file trực tiếp): có thể video
            // vốn không có tiếng. Không chặn, nhưng ghi rõ trạng thái.
            result.audioState = .missingInSource
        }
        return result
    }

    /// Thử lấy audio từ trang gốc (referrer) và ghép vào file video đã tải.
    ///
    /// Chỉ chạy một lần/task, chỉ khi referrer là trang HTML (không phải CDN
    /// media), và không bao giờ ném lỗi ra ngoài — thất bại thì trả `false` để
    /// caller quyết định fail hay hoàn tất kèm cảnh báo.
    private func repairAudio(task: DownloadTask, videoFile: URL) async -> Bool {
        let alreadyRepaired = repairedTaskIdsLock.withLock { repairedTaskIds.contains(task.id) }
        guard !alreadyRepaired else { return false }
        repairedTaskIdsLock.withLock { _ = repairedTaskIds.insert(task.id) }

        guard let refString = task.referrer,
              let pageURL = URL(string: refString),
              MediaURLResolver.isHTMLPageURL(pageURL),
              pageURL.absoluteString != task.url.absoluteString,
              !URLNormalizer.isBarePlatformHomeURL(pageURL) else {
            return false
        }
        guard MediaURLResolver.findYtDlpBinary() != nil else { return false }
        if isCancelledOrInactive(task.id) { return false }

        log.info("Thử ghép audio cho task \(task.id) từ trang \(pageURL.absoluteString)")
        let resolved = await MediaURLResolver.resolve(
            url: pageURL,
            customHeaders: task.headers,
            userAgent: task.userAgent,
            cookies: task.cookies
        )
        if isCancelledOrInactive(task.id) { return false }

        // Nguồn audio: ưu tiên stream .audio, sau đó file hợp nhất có audio.
        let audioSource: URL?
        if let audio = resolved.audioStream {
            audioSource = audio.url
        } else if let video = resolved.videoStream, video.includesAudio, !resolved.requiresMux {
            audioSource = video.url
        } else {
            audioSource = nil
        }
        guard let audioURL = audioSource, audioURL.absoluteString != task.url.absoluteString else {
            return false
        }

        let fileManager = FileManager.default
        let tempDir = task.tempDirectory
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        var downloadedAudio: URL?
        do {
            if audioURL.pathExtension.lowercased() == "m3u8" {
                let audioDest = tempDir.appendingPathComponent("repair_audio.ts")
                let downloader = HLSDownloader()
                let hlsResult = try await downloader.download(
                    playlistURL: audioURL,
                    destinationFile: audioDest,
                    tempDirectory: tempDir.appendingPathComponent("repair_hls"),
                    taskId: task.id,
                    cookies: task.cookies,
                    referrer: task.referrer,
                    userAgent: task.userAgent,
                    onProgress: { _, _, _, _, _, _ in }
                )
                downloadedAudio = hlsResult.destination
            } else {
                let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension.lowercased()
                let audioDest = tempDir.appendingPathComponent("repair_audio.\(ext)")
                try await downloadMediaPart(
                    url: audioURL,
                    destination: audioDest,
                    baseTask: task,
                    customHeaders: task.headers,
                    taskId: task.id,
                    progressWeight: 0
                )
                downloadedAudio = audioDest
            }
        } catch {
            log.error("repairAudio: tải audio thất bại: \(error.localizedDescription)")
            return false
        }
        guard let audioFile = downloadedAudio, fileManager.fileExists(atPath: audioFile.path),
              MediaIntegrity.report(of: audioFile)?.hasAudio == true else {
            return false
        }
        if isCancelledOrInactive(task.id) { return false }

        let containerExt = videoFile.pathExtension.lowercased()
        let muxContainerExt = containerExt.isEmpty ? "mp4" : containerExt
        let muxedFile = tempDir.appendingPathComponent("repair_muxed.\(muxContainerExt)")
        do {
            try MediaMuxer.mux(video: videoFile, audio: audioFile, output: muxedFile)
        } catch {
            log.error("repairAudio: ghép thất bại: \(error.localizedDescription)")
            return false
        }
        guard let report = MediaIntegrity.report(of: muxedFile), report.hasVideo, report.hasAudio else {
            return false
        }

        // Thay file gốc bằng bản đã có tiếng (giữ nguyên tên/tệp người dùng thấy).
        let backup = tempDir.appendingPathComponent("repair_backup.\(muxContainerExt)")
        do {
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: videoFile, to: backup)
            do {
                try fileManager.moveItem(at: muxedFile, to: videoFile)
            } catch {
                try? fileManager.moveItem(at: backup, to: videoFile)
                return false
            }
            try? fileManager.removeItem(at: backup)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Ghép video + âm thanh (nguồn DASH: YouTube, Bilibili…)

    /// Tải video-only và audio-only rồi ghép bằng ffmpeg.
    ///
    /// Nguồn DASH tách thành hai file riêng. Nếu chỉ tải video thì file ra **không có
    /// tiếng** — đây là lỗi từng làm video YouTube tải về bị mất âm thanh.
    private func executeMuxedDownload(
        task: DownloadTask,
        originalURL: URL,
        resolved: ResolvedMedia,
        customHeaders: [String: String]?
    ) async {
        let taskId = task.id
        guard let videoStream = resolved.videoStream, let audioStream = resolved.audioStream else { return }
        if isCancelledOrInactive(taskId) { return }

        let tempDir = task.tempDirectory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var workingTask = task
        let videoExt = (videoStream.ext ?? "mp4").lowercased()
        let audioExt = (audioStream.ext ?? "m4a").lowercased()
        let videoFile = tempDir.appendingPathComponent("video.\(videoExt)")
        let audioFile = tempDir.appendingPathComponent("audio.\(audioExt)")

        // Container đích: luôn chọn theo codec/stream video, không theo đuôi tên
        // người dùng nhập (tên trang thường không có đuôi; đuôi lạ làm ffmpeg
        // không suy ra được muxer).
        let containerExt: String = {
            let userExt = (workingTask.filename as NSString).pathExtension.lowercased()
            if ["mp4", "webm", "mkv", "mov"].contains(userExt) { return userExt }
            return MediaMuxer.preferredContainer(videoStreamExtension: videoStream.ext)
        }()

        let baseName = (workingTask.filename as NSString).deletingPathExtension
        let desiredName = baseName.isEmpty ? "video" : baseName
        if (workingTask.filename as NSString).pathExtension.lowercased() != containerExt {
            workingTask.filename = "\(desiredName).\(containerExt)"
        }
        let outputFile = workingTask.finalFilePath

        do {
            // 1) Tải phần video (80% tiến độ) rồi phần âm thanh (20%).
            try await downloadMediaPart(
                url: videoStream.url,
                destination: videoFile,
                baseTask: workingTask,
                customHeaders: customHeaders,
                taskId: taskId,
                progressWeight: 0.8
            )
            if isCancelledOrInactive(taskId) { throw CancellationError() }
            try await downloadMediaPart(
                url: audioStream.url,
                destination: audioFile,
                baseTask: workingTask,
                customHeaders: customHeaders,
                taskId: taskId,
                progressWeight: 0.2
            )
            if isCancelledOrInactive(taskId) { throw CancellationError() }

            // 2) Ghép bằng ffmpeg.
            try muxMediaParts(video: videoFile, audio: audioFile, output: outputFile)

            // 3) Kiểm chứng file ghép thật sự có cả hình lẫn tiếng rồi mới publish.
            if !Task.isCancelled, var completedTask = try? store.getTask(id: taskId), completedTask.status != .paused {
                completedTask.filename = workingTask.filename
                completedTask = await finalizeMediaTask(
                    completedTask,
                    fileURL: outputFile,
                    declaredAudio: true,
                    allowRepair: true
                )
                if completedTask.status == .failed {
                    try? store.saveTask(completedTask)
                    onDownloadFailed?(completedTask)
                    onTasksChanged?()
                    return
                }
                completedTask.status = .completed
                completedTask.speed = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputFile.path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 {
                    completedTask.totalBytes = size
                    completedTask.downloadedBytes = size
                }
                try? store.saveTask(completedTask)
                onDownloadCompleted?(completedTask)
            }
            onTasksChanged?()
        } catch {
            let isURLCancelled = (error as? URLError)?.code == .cancelled
            if error is CancellationError || isURLCancelled || isCancelledOrInactive(taskId) {
                onTasksChanged?()
                return
            }

            // Không ghép được (thiếu ffmpeg, codec lạ…) → thử để yt-dlp tự tải+ghép.
            // Phải dùng URL TRANG gốc, không phải URL video-only đã resolve, nếu không
            // yt-dlp sẽ tải đúng file video-only đó và âm thanh vẫn mất.
            var finalError = error
            log.error("Mux failed for task \(taskId): \(error.localizedDescription)")
            if let ytdlp = MediaURLResolver.findYtDlpBinary(), !isCancelledOrInactive(taskId) {
                var fallbackTask = workingTask
                fallbackTask.url = originalURL
                do {
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: fallbackTask, declaredAudio: true)
                    return
                } catch {
                    if error is CancellationError || isCancelledOrInactive(taskId) {
                        onTasksChanged?()
                        return
                    }
                    finalError = error
                }
            }

            if !Task.isCancelled, var failedTask = try? store.getTask(id: taskId), failedTask.status != .paused {
                failedTask.status = .failed
                failedTask.errorMessage = "Không ghép được video + âm thanh: \(finalError.localizedDescription)"
                failedTask.speed = 0
                try? store.saveTask(failedTask)
                onDownloadFailed?(failedTask)
            }
            onTasksChanged?()
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Tải một phần media (video hoặc audio) bằng engine range của app.
    private func downloadMediaPart(
        url: URL,
        destination: URL,
        baseTask: DownloadTask,
        customHeaders: [String: String]?,
        taskId: UUID,
        progressWeight: Double
    ) async throws {
        let partTask = DownloadTask(
            url: url,
            filename: destination.lastPathComponent,
            destinationFolder: destination.deletingLastPathComponent(),
            referrer: baseTask.referrer,
            userAgent: baseTask.userAgent,
            cookies: baseTask.cookies,
            headers: baseTask.headers
        )

        let probe = try await HTTPRangeDownloader.probeURL(
            url: url,
            customHeaders: customHeaders,
            cookies: baseTask.cookies,
            userAgent: baseTask.userAgent
        )

        var updatedTask = partTask
        updatedTask.totalBytes = probe.totalBytes
        updatedTask.acceptRanges = probe.acceptRanges

        let segments = HTTPRangeDownloader.calculateSegments(
            taskId: partTask.id,
            totalBytes: probe.totalBytes,
            segmentCount: 4,
            acceptRanges: probe.acceptRanges
        )

        let downloader = HTTPRangeDownloader()
        try await downloader.download(
            task: updatedTask,
            segments: segments,
            onProgress: { [weak self] downloaded, speed in
                guard let self = self else { return }
                if (try? self.store.getTask(id: taskId))?.status == .paused { return }
                if var t = try? self.store.getTask(id: taskId) {
                    t.downloadedBytes = Int64(Double(downloaded) * progressWeight)
                    t.totalBytes = t.totalBytes > 0 ? t.totalBytes : probe.totalBytes
                    t.speed = speed
                    try? self.store.saveTask(t)
                }
                self.onTaskProgressUpdated?(taskId, Int64(Double(downloaded) * progressWeight), probe.totalBytes, 0, 1, speed, [])
            },
            onSegmentUpdate: { _ in }
        )
    }

    /// Ghép video + audio bằng ffmpeg. Ném lỗi nếu không ghép được.
    private func muxMediaParts(video: URL, audio: URL, output: URL) throws {
        try MediaMuxer.mux(video: video, audio: audio, output: output)
    }

    /// Tên file đích khi tải HLS.
    ///
    /// Playlist `.m3u8` không phải file media: nếu giữ đuôi `.m3u8` thì bước remux
    /// của `HLSDownloader` (bước ghép nhánh âm thanh riêng) bị bỏ qua → file ra
    /// **không có tiếng** và mang tên sai.
    public static func hlsDestinationFile(for task: DownloadTask) -> URL {
        let target = task.finalFilePath
        let ext = target.pathExtension.lowercased()
        guard ext == "m3u8" || ext.isEmpty else { return target }
        let baseName = target.deletingPathExtension().lastPathComponent
        let clean = (baseName.isEmpty || baseName == "master" || baseName == "index") ? "video" : baseName
        return task.destinationFolder.appendingPathComponent("\(clean).mp4")
    }

    private func executeHLSDownload(task: DownloadTask, customHeaders: [String: String]? = nil) async {
        let taskId = task.id
        if isCancelledOrInactive(taskId) { return }
        let hlsDownloader = HLSDownloader()
        handleLock.withLock { activeHLSTasks[taskId] = hlsDownloader }

        // Playlist HLS tải về là file media, không phải playlist: tên đích phải
        // là .mp4. Nếu giữ đuôi .m3u8 thì bước remux của HLSDownloader (bước
        // ghép nhánh âm thanh riêng) bị bỏ qua → file ra **không có tiếng**.
        let targetFile = Self.hlsDestinationFile(for: task)
        if targetFile.lastPathComponent != task.filename {
            if var renamed = try? store.getTask(id: taskId), renamed.filename != targetFile.lastPathComponent {
                renamed.filename = targetFile.lastPathComponent
                try? store.saveTask(renamed)
            }
        }

        do {
            let hlsResult = try await hlsDownloader.download(
                playlistURL: task.url,
                destinationFile: targetFile,
                tempDirectory: task.tempDirectory,
                taskId: taskId,
                cookies: task.cookies,
                referrer: task.referrer,
                userAgent: task.userAgent,
                customHeaders: customHeaders ?? task.headers,
                onProgress: { [weak self] downloadedSegs, totalSegs, downloadedBytes, estimatedTotalBytes, speed, activeSegments in
                    guard let self = self else { return }
                    if (try? self.store.getTask(id: taskId))?.status == .paused { return }
                    self.handleLock.withLock {
                        self.liveSegments[taskId] = activeSegments
                    }
                    let now = Date().timeIntervalSince1970
                    let lastSave = self.handleLock.withLock { self.lastDBSaveTime[taskId] ?? 0 }
                    if now - lastSave >= 1.0 || downloadedSegs == totalSegs {
                        self.handleLock.withLock { self.lastDBSaveTime[taskId] = now }
                        if var t = try? self.store.getTask(id: taskId), t.status != .paused {
                            t.downloadedBytes = downloadedBytes
                            t.totalBytes = estimatedTotalBytes
                            t.downloadedSegmentsCount = downloadedSegs
                            t.segmentsCount = totalSegs
                            t.speed = speed
                            try? self.store.saveTask(t)
                        }
                        if !activeSegments.isEmpty {
                            try? self.store.saveSegments(activeSegments)
                        }
                    }
                    self.onTaskProgressUpdated?(taskId, downloadedBytes, estimatedTotalBytes, downloadedSegs, totalSegs, speed, activeSegments)
                }
            )

            if !Task.isCancelled, var completed = try? store.getTask(id: taskId), completed.status != .paused {
                completed = await finalizeMediaTask(
                    completed,
                    fileURL: hlsResult.destination,
                    declaredAudio: hlsResult.hadSeparateAudio ? true : nil,
                    allowRepair: true
                )
                if completed.status == .failed {
                    try? store.saveTask(completed)
                    onDownloadFailed?(completed)
                    handleLock.withLock {
                        activeHLSTasks.removeValue(forKey: taskId)
                        liveSegments.removeValue(forKey: taskId)
                        lastDBSaveTime.removeValue(forKey: taskId)
                    }
                    onTasksChanged?()
                    return
                }
                completed.status = .completed
                completed.speed = 0
                completed.filename = hlsResult.destination.lastPathComponent
                if let attrs = try? FileManager.default.attributesOfItem(atPath: hlsResult.destination.path),
                   let size = attrs[.size] as? Int64, size > 0 {
                    completed.totalBytes = size
                    completed.downloadedBytes = size
                }
                try store.saveTask(completed)
                onDownloadCompleted?(completed)
            }
            handleLock.withLock {
                activeHLSTasks.removeValue(forKey: taskId)
                liveSegments.removeValue(forKey: taskId)
                lastDBSaveTime.removeValue(forKey: taskId)
            }
            onTasksChanged?()
        } catch {
            handleLock.withLock {
                activeHLSTasks.removeValue(forKey: taskId)
                liveSegments.removeValue(forKey: taskId)
                lastDBSaveTime.removeValue(forKey: taskId)
            }
            let isURLCancelled = (error as? URLError)?.code == .cancelled
            if error is CancellationError || isURLCancelled || isCancelledOrInactive(taskId) {
                onTasksChanged?()
                return
            }
            var finalError = error
            log.error("HLS download failed for task \(taskId): \(error.localizedDescription)")

            // Self-healing: If 403 Forbidden occurred on an embed/probe stream (e.g. recordplay.biz/stream/...):
            if let ref = task.referrer, let embedURL = URL(string: ref),
               (ref.contains("recordplay.biz/e/") || task.url.host?.contains("recordplay.biz") == true) {
                if let resolved = await MediaURLResolver.resolveEmbedStream(embedURL: embedURL) {
                    if isCancelledOrInactive(taskId) { return }
                    if resolved.directURL != task.url {
                        var updatedTask = task
                        updatedTask.url = resolved.directURL
                        updatedTask.referrer = ref
                        if let newHost = resolved.directURL.host, !ref.contains(newHost) {
                            updatedTask.cookies = nil
                        }
                        try? store.saveTask(updatedTask)
                        await executeHLSDownload(task: updatedTask)
                        return
                    }
                }
            }

            if let ytdlp = MediaURLResolver.findYtDlpBinary(), !isCancelledOrInactive(taskId) {
                do {
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: task, declaredAudio: nil)
                    return
                } catch {
                    let isSubCancelled = (error as? URLError)?.code == .cancelled
                    if error is CancellationError || isSubCancelled || isCancelledOrInactive(taskId) {
                        onTasksChanged?()
                        return
                    }
                    finalError = error
                }
            }
            if !Task.isCancelled, var failed = try? store.getTask(id: taskId), failed.status != .paused {
                failed.status = .failed
                failed.errorMessage = finalError.localizedDescription
                failed.speed = 0
                try? store.saveTask(failed)
                onDownloadFailed?(failed)
            }
            onTasksChanged?()
        }
    }

    private func downloadWithYtDlp(binaryPath: String, task: DownloadTask, declaredAudio: Bool? = nil) async throws {
        let taskId = task.id
        if isCancelledOrInactive(taskId) {
            throw CancellationError()
        }
        var currentTask = task

        var targetFile = task.finalFilePath
        let ext = targetFile.pathExtension.lowercased()
        if ext == "m3u8" || ext.isEmpty {
            let baseName = targetFile.deletingPathExtension().lastPathComponent
            let clean = (baseName.isEmpty || baseName == "master" || baseName == "index") ? "video" : baseName
            targetFile = task.destinationFolder.appendingPathComponent("\(clean).mp4")
            currentTask.filename = targetFile.lastPathComponent
            if !isCancelledOrInactive(taskId) {
                try? store.saveTask(currentTask)
            }
        }

        let targetDir = targetFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: targetDir.path) {
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/Library/Frameworks/Python.framework/Versions/3.14/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        proc.environment = env

        var args = [
            "--no-warnings",
            "--continue",
            "--hls-use-mpegts",
            "-N", "4",
            "--newline",
            "-o", targetFile.path
        ]

        let ffmpegBinary = MediaURLResolver.findFfmpegBinary()
        if let ffmpeg = ffmpegBinary {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg])
            // Chọn rõ format: video tốt nhất + audio tốt nhất, fallback format
            // hợp nhất. Không truyền -f thì config người dùng có thể ép video-only.
            args.append(contentsOf: ["-f", "bv*+ba/b"])
        } else {
            // Không có ffmpeg thì yt-dlp KHÔNG thể merge (nó sẽ tải 2 file rời và
            // exit 0 — đây chính là nguồn gốc lỗi "video mất tiếng"). Ép lấy
            // format hợp nhất sẵn; nếu nguồn không có, phần kiểm chứng bên dưới
            // sẽ báo lỗi thay vì publish file câm.
            args.append(contentsOf: ["-f", "b"])
            log.warning("Không tìm thấy ffmpeg — chỉ tải được format hợp nhất sẵn cho task \(taskId)")
        }

        var ffmpegArgs = "ffmpeg:-allowed_extensions ALL"
        let effectiveUA = task.userAgent ?? URLNormalizer.defaultUserAgent
        args.append(contentsOf: ["--user-agent", effectiveUA])

        if let ref = task.referrer ?? task.url.host.map({ "https://\($0)/" }) {
            args.append(contentsOf: ["--referer", ref])
            ffmpegArgs += " -headers Referer:\\ \(ref)\\r\\n"
        }

        args.append(contentsOf: ["--downloader-args", ffmpegArgs])

        let isVideoPlatform = URLNormalizer.isVideoPlatformURL(task.url)
        if !isVideoPlatform, let cookies = task.cookies, !cookies.isEmpty {
            args.append(contentsOf: ["--add-header", "Cookie: \(cookies)"])
        }

        if let headers = task.headers {
            for (k, v) in headers {
                let lowerK = k.lowercased()
                if lowerK != "cookie" && lowerK != "user-agent" && lowerK != "referer" {
                    args.append(contentsOf: ["--add-header", "\(k): \(v)"])
                }
            }
        }

        args.append(task.url.absoluteString)

        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        handleLock.withLock { activeProcesses[taskId] = proc }
        defer {
            _ = handleLock.withLock { activeProcesses.removeValue(forKey: taskId) }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: .newlines)
            for line in lines {
                self?.parseYtDlpProgress(line: line, taskId: taskId)
            }
        }

        try proc.run()
        proc.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil

        if isCancelledOrInactive(taskId) {
            throw CancellationError()
        }

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let rawErrMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errLines = rawErrMsg.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("WARNING:") }
            let errMsg = (errLines.first(where: { $0.hasPrefix("ERROR:") }) ?? errLines.last) ?? rawErrMsg

            // A-F20: guard let thay `task.cookies!` (giữ hành vi: chỉ strip khi có cookie).
            let hasCookies = !(task.cookies?.isEmpty ?? true)
            // A-F3: mọi truy cập taskStrippedCookies qua handleLock (tránh data race
            // giữa các Task yt-dlp chạy đồng thời).
            let alreadyStripped = handleLock.withLock { taskStrippedCookies.contains(taskId) }
            if hasCookies && !alreadyStripped {
                _ = handleLock.withLock { taskStrippedCookies.insert(taskId) }
                var retryTask = task
                retryTask.cookies = nil
                return try await downloadWithYtDlp(binaryPath: binaryPath, task: retryTask, declaredAudio: declaredAudio)
            }

            if (rawErrMsg.contains("403") || rawErrMsg.contains("Forbidden")) {
                let host = task.url.host ?? ""
                let currentRef = task.referrer ?? ""
                let hasForeignReferer = !host.isEmpty && !currentRef.contains(host)

                if hasForeignReferer {
                    var retryTask = task
                    retryTask.referrer = "https://\(host)/"
                    return try await downloadWithYtDlp(binaryPath: binaryPath, task: retryTask, declaredAudio: declaredAudio)
                }
            }
            throw NSError(domain: "DownloadManager.yt-dlp", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errMsg.isEmpty ? "yt-dlp exited with code \(proc.terminationStatus)" : errMsg
            ])
        }

        // yt-dlp có thể để lại file rời `video.f137.mp4` + `video.f251.webm` khi
        // không merge được (thiếu ffmpeg) → phải tự ghép, không chọn bừa 1 file.
        if let recovered = try recoverYtDlpSplitOutput(
            targetFile: targetFile,
            folder: task.destinationFolder,
            task: currentTask,
            declaredAudio: declaredAudio
        ) {
            targetFile = recovered.url
            currentTask.filename = recovered.url.lastPathComponent
            if !isCancelledOrInactive(taskId) {
                try? store.saveTask(currentTask)
            }
        }

        if !Task.isCancelled, var completed = try? store.getTask(id: taskId), completed.status != .paused {
            completed = await finalizeMediaTask(
                completed,
                fileURL: targetFile,
                declaredAudio: declaredAudio,
                allowRepair: true
            )
            if completed.status == .failed {
                try? store.saveTask(completed)
                onDownloadFailed?(completed)
                onTasksChanged?()
                return
            }
            completed.status = .completed
            completed.speed = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: targetFile.path),
               let size = attrs[.size] as? Int64 {
                completed.totalBytes = size
                completed.downloadedBytes = size
            }
            try? store.saveTask(completed)
            onDownloadCompleted?(completed)
        }
        onTasksChanged?()
    }

    /// Khôi phục kết quả yt-dlp khi nó để lại các file rời (`.fNNN.`) thay vì
    /// một file hoàn chỉnh (thiếu ffmpeg hoặc merge lỗi).
    ///
    /// Probe từng file rời để phân loại video-only / audio-only; nếu có đủ cặp
    /// thì ghép bằng `MediaMuxer`. **Không** chọn "file đầu tiên khớp prefix"
    /// như trước đây (có thể chọn nhầm audio-only hoặc video-only).
    func recoverYtDlpSplitOutput(
        targetFile: URL,
        folder: URL,
        task: DownloadTask,
        declaredAudio: Bool?
    ) throws -> (url: URL, repaired: Bool)? {
        let fileManager = FileManager.default
        let baseName = targetFile.deletingPathExtension().lastPathComponent
        guard let items = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }

        let siblings = items
            .filter { $0.hasPrefix(baseName + ".") && !$0.hasSuffix(".part") }
            .map { folder.appendingPathComponent($0) }

        if fileManager.fileExists(atPath: targetFile.path) {
            if declaredAudio != true { return (targetFile, false) }
            if MediaIntegrity.report(of: targetFile)?.hasAudio == true { return (targetFile, false) }
        }
        guard !siblings.isEmpty else { return nil }

        var videoOnly: URL?
        var audioOnly: URL?
        for sibling in siblings {
            guard let report = MediaIntegrity.report(of: sibling) else { continue }
            if report.hasVideo && report.hasAudio {
                return (sibling, false)
            } else if report.hasVideo && videoOnly == nil {
                videoOnly = sibling
            } else if report.hasAudio && audioOnly == nil {
                audioOnly = sibling
            }
        }

        if let video = videoOnly, let audio = audioOnly {
            let ext = MediaMuxer.preferredContainer(videoStreamExtension: video.pathExtension)
            let muxed = folder.appendingPathComponent("\(baseName).\(ext)")
            try MediaMuxer.mux(video: video, audio: audio, output: muxed)
            guard let report = MediaIntegrity.report(of: muxed), report.hasVideo, report.hasAudio else {
                return nil
            }
            try? fileManager.removeItem(at: video)
            try? fileManager.removeItem(at: audio)
            if muxed != targetFile { try? fileManager.removeItem(at: targetFile) }
            return (muxed, true)
        }
        if let video = videoOnly { return (video, false) }
        if let audio = audioOnly { return (audio, false) }
        return nil
    }

    private func parseYtDlpProgress(line: String, taskId: UUID) {
        guard line.contains("[download]") else { return }

        var speed: Double = 0.0
        var totalBytes: Int64 = -1
        var downloadedBytes: Int64 = 0

        if let speedRange = line.range(of: #"at\s+([\d\.]+)\s*([KMGT]?i?B)/s"#, options: .regularExpression) {
            let speedSub = String(line[speedRange])
            let parts = speedSub.replacingOccurrences(of: "at", with: "").replacingOccurrences(of: "/s", with: "").trimmingCharacters(in: .whitespaces)
            let scanner = Scanner(string: parts)
            if let num = scanner.scanDouble() {
                let unit = scanner.string.trimmingCharacters(in: .whitespaces).lowercased()
                if unit.hasPrefix("k") { speed = num * 1024 }
                else if unit.hasPrefix("m") { speed = num * 1024 * 1024 }
                else if unit.hasPrefix("g") { speed = num * 1024 * 1024 * 1024 }
                else { speed = num }
            }
        }

        var percent: Double?
        if let pctRange = line.range(of: #"([\d\.]+)%"#, options: .regularExpression) {
            let pctStr = line[pctRange].replacingOccurrences(of: "%", with: "")
            percent = Double(pctStr)
        }

        if let sizeRange = line.range(of: #"of\s+~?\s*([\d\.]+)\s*([KMGT]?i?B)"#, options: .regularExpression) {
            let sizeSub = String(line[sizeRange])
            let parts = sizeSub.replacingOccurrences(of: "of", with: "").replacingOccurrences(of: "~", with: "").trimmingCharacters(in: .whitespaces)
            let scanner = Scanner(string: parts)
            if let num = scanner.scanDouble() {
                let unit = scanner.string.trimmingCharacters(in: .whitespaces).lowercased()
                var multiplier: Double = 1.0
                if unit.hasPrefix("k") { multiplier = 1024 }
                else if unit.hasPrefix("m") { multiplier = 1024 * 1024 }
                else if unit.hasPrefix("g") { multiplier = 1024 * 1024 * 1024 }
                totalBytes = Int64(num * multiplier)
                if let pct = percent {
                    downloadedBytes = Int64(Double(totalBytes) * (pct / 100.0))
                }
            }
        }

        if let fragRange = line.range(of: #"\(frag\s+(\d+)/(\d+)\)"#, options: .regularExpression) {
            let fragSub = String(line[fragRange])
            let digits = fragSub.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if digits.count >= 2, let cur = Int(digits[0]), let tot = Int(digits[1]) {
                if var t = try? store.getTask(id: taskId), t.status != .paused {
                    t.downloadedSegmentsCount = cur
                    t.segmentsCount = tot
                    try? store.saveTask(t)
                }
            }
        }

        if var t = try? store.getTask(id: taskId), t.status != .paused {
            if totalBytes > 0 { t.totalBytes = totalBytes }
            if downloadedBytes > 0 { t.downloadedBytes = downloadedBytes }
            t.speed = speed
            try? store.saveTask(t)
            onTaskProgressUpdated?(taskId, t.downloadedBytes, t.totalBytes, t.downloadedSegmentsCount, t.segmentsCount, speed, [])
        }
    }

    public func pauseDownload(taskId: UUID) {
        if getTask(id: taskId)?.browserInfo != nil {
            Task { await browserTransfers.cancel(taskId) }; return
        }
        let currentSegments = handleLock.withLock { liveSegments[taskId] }
        var sumDownloaded: Int64 = 0
        if var segs = currentSegments, !segs.isEmpty {
            for i in 0..<segs.count {
                if segs[i].status == .downloading {
                    segs[i].status = .paused
                }
                sumDownloaded += segs[i].downloadedBytes
            }
            try? store.saveSegments(segs)
        }
        if var task = getTask(id: taskId) {
            task.status = .paused
            task.speed = 0
            if sumDownloaded > task.downloadedBytes {
                task.downloadedBytes = sumDownloaded
            }
            try? store.saveTask(task)
        }
        handleLock.withLock { activeTaskHandles[taskId]?.cancel() }
        if let downloader = handleLock.withLock({ activeDownloaders[taskId] }) {
            Task { await downloader.pause() }
        }
        if let downloader = handleLock.withLock({ activeHLSTasks[taskId] }) { Task { await downloader.cancel() } }
        if let proc = handleLock.withLock({ activeProcesses[taskId] }) {
            proc.terminate()
        }
        onTasksChanged?()
    }

    public func pauseAllTasks() {
        let active = getAllTasks().filter { $0.status == .downloading || $0.status == .pending }
        for task in active {
            pauseDownload(taskId: task.id)
        }
    }

    public func resumeAllTasks() {
        let activeIds = handleLock.withLock {
            Set(activeTaskHandles.filter { !$0.value.isCancelled }.keys)
        }
        let resumable = getAllTasks().filter {
            $0.status == .paused || $0.status == .failed || ($0.status == .pending && !activeIds.contains($0.id))
        }
        for task in resumable {
            startDownload(taskId: task.id)
        }
    }

    public func deleteTask(taskId: UUID) {
        if getTask(id: taskId)?.browserInfo != nil {
            Task {
                await browserTransfers.cancel(taskId)
                try? store.deleteTask(id: taskId)
                onTasksChanged?()
            }
            return
        }
        let task = getTask(id: taskId)
        let runningHandle = handleLock.withLock { activeTaskHandles[taskId] }
        pauseDownload(taskId: taskId)
        if let task = task {
            let tempDir = task.tempDirectory
            try? FileManager.default.removeItem(at: tempDir)
            try? store.deleteTask(id: taskId)
            onTasksChanged?()
            if let runningHandle = runningHandle {
                Task {
                    await runningHandle.value
                    try? FileManager.default.removeItem(at: tempDir)
                }
            }
        }
    }

    public func clearFailedTasks() throws {
        let allFailed = getAllTasks().filter { $0.status == .failed }
        for task in allFailed {
            try? FileManager.default.removeItem(at: task.tempDirectory)
        }
        try store.deleteFailedTasks()
        onTasksChanged?()
    }

    public func clearCompletedAndFailedTasks() throws {
        let removable = getAllTasks().filter { $0.status == .completed || $0.status == .failed }
        for task in removable {
            try? FileManager.default.removeItem(at: task.tempDirectory)
        }
        try store.deleteCompletedAndFailedTasks()
        onTasksChanged?()
    }

    public func shutdown() {
        pauseAllTasks()

        let handles = handleLock.withLock {
            let h = Array(activeTaskHandles.values)
            activeTaskHandles.removeAll()
            activeTaskTokens.removeAll()
            return h
        }
        for h in handles { h.cancel() }

        let downloaders = handleLock.withLock {
            let d = Array(activeDownloaders.values)
            activeDownloaders.removeAll()
            return d
        }
        for d in downloaders { Task { await d.pause() } }

        let hlsTasks = handleLock.withLock {
            let h = Array(activeHLSTasks.values)
            activeHLSTasks.removeAll()
            return h
        }
        for h in hlsTasks { Task { await h.cancel() } }

        let procs = handleLock.withLock {
            let p = Array(activeProcesses.values)
            activeProcesses.removeAll()
            return p
        }
        for p in procs where p.isRunning {
            p.terminate()
        }

        stopIPC()
    }

    /// Người dùng bấm "Tải lại bằng yt-dlp" cho task lỗi mất tiếng: xoá dấu
    /// "đã thử repair" rồi chạy lại để cổng kiểm chứng/repair có cơ hội thứ hai.
    public func retryAudioRepair(taskId: UUID) {
        repairedTaskIdsLock.withLock { _ = repairedTaskIds.remove(taskId) }
        guard var task = getTask(id: taskId) else { return }
        task.status = .paused
        task.errorMessage = nil
        task.audioState = nil
        task.speed = 0
        try? store.saveTask(task)
        startDownload(taskId: taskId)
    }

    public func updateTaskURL(taskId: UUID, newURL: URL, newReferrer: String? = nil) throws {
        guard var task = getTask(id: taskId) else { return }
        task.url = newURL
        if let ref = newReferrer, !ref.isEmpty {
            task.referrer = ref
        }
        task.errorMessage = nil
        task.status = .paused
        task.speed = 0
        try store.saveTask(task)
        onTasksChanged?()
    }

    public func updateTaskSettings(taskId: UUID, filename: String, destinationFolder: URL, segmentsCount: Int, totalBytes: Int64? = nil) {
        guard var task = getTask(id: taskId) else { return }
        let cleanFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFilename.isEmpty {
            task.filename = cleanFilename
        }
        task.destinationFolder = destinationFolder
        task.segmentsCount = segmentsCount
        if let tb = totalBytes, tb > 0 {
            task.totalBytes = tb
        }
        try? store.saveTask(task)
        onTasksChanged?()
    }
}
