import Foundation

public final class DownloadManager: @unchecked Sendable {
    public static let shared = DownloadManager()

    public let store: SQLiteStore
    public let ipcServer: UnixDomainSocketServer
    private let queue = DispatchQueue(label: "com.internetdownloader.manager", attributes: .concurrent)

    private var activeDownloaders: [UUID: HTTPRangeDownloader] = [:]
    private var activeHLSTasks: [UUID: HLSDownloader] = [:]
    private var activeProcesses: [UUID: Process] = [:]
    private var activeTaskHandles: [UUID: Task<Void, Never>] = [:]
    private var activeTaskTokens: [UUID: UUID] = [:]
    private let handleLock = NSLock()
    private let slots = DownloadSlots()
    private var browserTransfers: BrowserTransfers!
    private var taskStrippedCookies = Set<UUID>()
    private var liveSegments: [UUID: [DownloadSegment]] = [:]
    private var lastDBSaveTime: [UUID: Double] = [:]

    public var onTasksChanged: (@Sendable () -> Void)?
    public var onTaskProgressUpdated: (@Sendable (UUID, Int64, Int64, Int, Int, Double, [DownloadSegment]) -> Void)?
    public var onDownloadStarted: (@Sendable (DownloadTask) -> Void)?
    public var onDownloadCompleted: (@Sendable (DownloadTask) -> Void)?
    public var onDownloadConfirmationRequested: (@Sendable (DownloadTask) -> Void)?

    public init(dbPath: String? = nil) {
        let path: String
        if let customPath = dbPath ?? ProcessInfo.processInfo.environment["IDM_DB_PATH"] {
            path = customPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("InternetDownloader")
            path = appDir.appendingPathComponent("downloader.sqlite3").path
        }

        do {
            self.store = try SQLiteStore(path: path)
        } catch {
            fatalError("Could not initialize SQLiteStore: \(error)")
        }

        self.ipcServer = UnixDomainSocketServer(socketPath: ProcessInfo.processInfo.environment["IDM_SOCKET_PATH"] ?? UnixDomainSocketServer.defaultSocketPath)
        self.browserTransfers = BrowserTransfers(store: store, slots: slots,
            destination: ProcessInfo.processInfo.environment["IDM_DESTINATION"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!,
            notify: { [weak self] in self?.onTasksChanged?() })
        for var task in getAllTasks() where task.browserInfo != nil && task.status != .completed && task.status != .failed {
            task.status = .failed; task.errorMessage = BrowserFailure.reconnect.localizedDescription
            task.browserInfo?.phase = "failed"; task.browserInfo?.errorCode = BrowserFailure.reconnect.rawValue
            try? store.saveTask(task)
        }
        setupIPCHandler()
    }

    public func startIPC() {
        do {
            try ipcServer.start()
        } catch {
            print("Failed to start IPC Server: \(error)")
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
                return IPCResponse(success: request.protocolVersion == 2, message: request.protocolVersion == 2 ? "Ready" : "App/extension cần cập nhật cùng phiên bản.", extra: ["protocolVersion": "2", "appVersion": "1.1.0"])
            }

            switch request.action {
            case "start_download":
                guard let urlStr = request.url, let url = URLNormalizer.normalize(urlStr) else {
                    let browserSource = request.url?.lowercased().hasPrefix("blob:") == true || URL(string: request.url ?? "")?.host?.lowercased() == "web.telegram.org"
                    return IPCResponse(success: false, message: browserSource ? "Nguồn này cần Save qua Chrome. Chọn lại attachment bằng extension mới." : "Invalid URL",
                        extra: ["code": browserSource ? "browser_source_required" : "invalid_url", "stage": "discovery"])
                }

                let defaultDest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                do {
                    if let confirmation = self.onDownloadConfirmationRequested {
                        let now = Date()
                        let existingPending = self.getAllTasks().first { existing in
                            guard existing.status == .pending,
                                  existing.downloadedBytes == 0,
                                  now.timeIntervalSince(existing.createdAt) < 5.0,
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
                            return IPCResponse(success: true, taskId: existing.id.uuidString, message: "Awaiting confirmation")
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
                    if let confirmation = self.onDownloadConfirmationRequested {
                        confirmation(task)
                        return IPCResponse(success: true, taskId: task.id.uuidString, message: "Awaiting confirmation")
                    } else {
                        self.startDownload(taskId: task.id)
                        return IPCResponse(success: true, taskId: task.id.uuidString, message: "Download started")
                    }
                } catch {
                    return IPCResponse(success: false, message: error.localizedDescription)
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

    public static func categorizedFolder(for filename: String, baseFolder: URL) -> URL {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
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

    private func isCancelledOrInactive(_ taskId: UUID) -> Bool {
        if Task.isCancelled { return true }
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

        if !MediaURLResolver.isDirectMediaURL(currentTask.url) {
            let resolved = await MediaURLResolver.resolve(
                url: currentTask.url,
                customHeaders: effectiveHeaders.isEmpty ? nil : effectiveHeaders,
                userAgent: currentTask.userAgent,
                cookies: currentTask.cookies
            )
            if isCancelledOrInactive(currentTask.id) { return }
            if resolved.directURL != currentTask.url {
                currentTask.url = resolved.directURL
                if currentTask.filename == "download" || currentTask.filename.isEmpty {
                    if let title = resolved.title, !title.isEmpty {
                        currentTask.filename = resolved.suggestedFilename ?? "\(title).mp4"
                    }
                }
                if let ref = resolved.headers["Referer"], currentTask.referrer == nil {
                    currentTask.referrer = ref
                    effectiveHeaders["Referer"] = ref
                }
                if let ua = resolved.headers["User-Agent"], currentTask.userAgent == nil {
                    currentTask.userAgent = ua
                }
                if let newHost = resolved.directURL.host, let oldHost = task.url.host, newHost != oldHost {
                    currentTask.cookies = nil
                }
                try? store.saveTask(currentTask)
            }
        }

        if isCancelledOrInactive(currentTask.id) { return }

        // 3. Check if MPEG-DASH (.mpd) stream
        let isDASH = currentTask.url.pathExtension.lowercased() == "mpd" || currentTask.url.absoluteString.contains(".mpd")
        if isDASH {
            if let ytdlp = MediaURLResolver.findYtDlpBinary() {
                do {
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: currentTask)
                    return
                } catch {
                    if error is CancellationError || isCancelledOrInactive(currentTask.id) {
                        onTasksChanged?()
                        return
                    }
                    // Fall back to standard range probe if yt-dlp fails
                }
            }
        }

        // 4. Check if HLS stream (.m3u8)
        if currentTask.url.pathExtension.lowercased() == "m3u8" || currentTask.url.absoluteString.contains(".m3u8") {
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
                }
            )

            if !Task.isCancelled, var completedTask = try? store.getTask(id: taskId), completedTask.status == .downloading {
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
                if currentExt.isEmpty || FileTypeDetector.isOpaqueIdentifier(completedTask.filename) {
                    if let detectedExt = FileTypeDetector.detectExtension(fileURL: targetFile) {
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
            ].contains(ext) || URLNormalizer.isVideoPlatformURL(currentTask.url)

            if isMediaCandidate, let ytdlp = MediaURLResolver.findYtDlpBinary(), !isCancelledOrInactive(taskId) {
                do {
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: currentTask)
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
            }
            onTasksChanged?()
        }
    }

    private func executeHLSDownload(task: DownloadTask, customHeaders: [String: String]? = nil) async {
        let taskId = task.id
        if isCancelledOrInactive(taskId) { return }
        let hlsDownloader = HLSDownloader()
        handleLock.withLock { activeHLSTasks[taskId] = hlsDownloader }

        do {
            try await hlsDownloader.download(
                playlistURL: task.url,
                destinationFile: task.finalFilePath,
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
                completed.status = .completed
                completed.speed = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: task.finalFilePath.path),
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
                    try await downloadWithYtDlp(binaryPath: ytdlp, task: task)
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
            }
            onTasksChanged?()
        }
    }

    private func downloadWithYtDlp(binaryPath: String, task: DownloadTask) async throws {
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

        if let ffmpeg = MediaURLResolver.findFfmpegBinary() {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg])
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

            let hasCookies = task.cookies != nil && !task.cookies!.isEmpty
            if hasCookies && !taskStrippedCookies.contains(taskId) {
                taskStrippedCookies.insert(taskId)
                var retryTask = task
                retryTask.cookies = nil
                return try await downloadWithYtDlp(binaryPath: binaryPath, task: retryTask)
            }

            if (rawErrMsg.contains("403") || rawErrMsg.contains("Forbidden")) {
                let host = task.url.host ?? ""
                let currentRef = task.referrer ?? ""
                let hasForeignReferer = !host.isEmpty && !currentRef.contains(host)

                if hasForeignReferer {
                    var retryTask = task
                    retryTask.referrer = "https://\(host)/"
                    return try await downloadWithYtDlp(binaryPath: binaryPath, task: retryTask)
                }
            }
            throw NSError(domain: "DownloadManager.yt-dlp", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errMsg.isEmpty ? "yt-dlp exited with code \(proc.terminationStatus)" : errMsg
            ])
        }

        if !FileManager.default.fileExists(atPath: targetFile.path) {
            let baseName = targetFile.deletingPathExtension().lastPathComponent
            if let items = try? FileManager.default.contentsOfDirectory(atPath: task.destinationFolder.path),
               let match = items.first(where: { $0.hasPrefix(baseName) && !$0.hasSuffix(".part") }) {
                targetFile = task.destinationFolder.appendingPathComponent(match)
                currentTask.filename = match
                if !isCancelledOrInactive(taskId) {
                    try? store.saveTask(currentTask)
                }
            }
        }

        if !Task.isCancelled, var completed = try? store.getTask(id: taskId), completed.status != .paused {
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
