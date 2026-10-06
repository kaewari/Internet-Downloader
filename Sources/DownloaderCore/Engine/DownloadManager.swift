import Foundation

public final class DownloadManager: @unchecked Sendable {
    public static let shared = DownloadManager()

    public let store: SQLiteStore
    public let ipcServer: UnixDomainSocketServer
    private let queue = DispatchQueue(label: "com.internetdownloader.manager", attributes: .concurrent)

    private var activeDownloaders: [UUID: HTTPRangeDownloader] = [:]
    private var activeHLSTasks: [UUID: HLSDownloader] = [:]
    private var activeTaskHandles: [UUID: Task<Void, Never>] = [:]

    public var onTasksChanged: (@Sendable () -> Void)?
    public var onTaskProgressUpdated: (@Sendable (UUID, Int64, Double, [DownloadSegment]) -> Void)?

    public init(dbPath: String? = nil) {
        let path: String
        if let customPath = dbPath {
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

        self.ipcServer = UnixDomainSocketServer()
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

            switch request.action {
            case "start_download":
                guard let urlStr = request.url, let url = URL(string: urlStr) else {
                    return IPCResponse(success: false, message: "Invalid URL")
                }

                let defaultDest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                do {
                    let task = try self.createNewTask(
                        url: url,
                        filename: request.filename ?? "",
                        destinationFolder: defaultDest,
                        referrer: request.referrer,
                        userAgent: request.userAgent,
                        cookies: request.cookies
                    )
                    self.startDownload(taskId: task.id)
                    return IPCResponse(success: true, taskId: task.id.uuidString, message: "Download started")
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
        (try? store.getSegments(for: taskId)) ?? []
    }

    public func createNewTask(
        url: URL,
        filename: String = "",
        destinationFolder: URL,
        segmentsCount: Int = 8,
        referrer: String? = nil,
        userAgent: String? = nil,
        cookies: String? = nil
    ) throws -> DownloadTask {
        var cleanFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanFilename.isEmpty {
            cleanFilename = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        }

        let task = DownloadTask(
            url: url,
            filename: cleanFilename,
            destinationFolder: destinationFolder,
            totalBytes: -1,
            downloadedBytes: 0,
            status: .pending,
            segmentsCount: segmentsCount,
            referrer: referrer,
            userAgent: userAgent,
            cookies: cookies
        )

        try store.saveTask(task)
        onTasksChanged?()
        return task
    }

    public func startDownload(taskId: UUID) {
        guard let task = getTask(id: taskId) else { return }

        // Cancel any existing task handle
        activeTaskHandles[taskId]?.cancel()

        let handle = Task { [weak self] in
            guard let self = self else { return }
            await self.executeDownload(task: task)
        }
        activeTaskHandles[taskId] = handle
    }

    private func executeDownload(task: DownloadTask) async {
        var currentTask = task
        currentTask.status = .downloading
        currentTask.errorMessage = nil
        try? store.saveTask(currentTask)
        onTasksChanged?()

        // Check if HLS stream (.m3u8)
        if currentTask.url.pathExtension.lowercased() == "m3u8" || currentTask.url.absoluteString.contains(".m3u8") {
            await executeHLSDownload(task: currentTask)
            return
        }

        // Standard HTTP / HTTPS Range Download
        do {
            let probe = try await HTTPRangeDownloader.probeURL(
                url: currentTask.url,
                cookies: currentTask.cookies,
                userAgent: currentTask.userAgent
            )

            currentTask.totalBytes = probe.totalBytes
            currentTask.acceptRanges = probe.acceptRanges
            currentTask.etag = probe.etag
            currentTask.lastModified = probe.lastModified
            if let suggested = probe.suggestedFilename, !suggested.isEmpty && currentTask.filename == "download" {
                currentTask.filename = suggested
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
            let downloader = HTTPRangeDownloader()
            activeDownloaders[taskId] = downloader

            try await downloader.download(
                task: currentTask,
                segments: segments,
                onProgress: { [weak self] downloadedBytes, speed in
                    guard let self = self else { return }
                    if var t = try? self.store.getTask(id: taskId) {
                        t.downloadedBytes = downloadedBytes
                        t.speed = speed
                        try? self.store.saveTask(t)
                    }
                    let currentSegments = (try? self.store.getSegments(for: taskId)) ?? []
                    self.onTaskProgressUpdated?(taskId, downloadedBytes, speed, currentSegments)
                },
                onSegmentUpdate: { [weak self] updatedSeg in
                    guard let self = self else { return }
                    try? self.store.saveSegments([updatedSeg])
                }
            )

            if var completedTask = try? store.getTask(id: taskId) {
                completedTask.status = .completed
                completedTask.speed = 0
                if completedTask.totalBytes > 0 {
                    completedTask.downloadedBytes = completedTask.totalBytes
                }
                try store.saveTask(completedTask)
            }
            activeDownloaders.removeValue(forKey: taskId)
            onTasksChanged?()
        } catch {
            let taskId = currentTask.id
            if var failedTask = try? store.getTask(id: taskId) {
                failedTask.status = .failed
                failedTask.errorMessage = error.localizedDescription
                failedTask.speed = 0
                try? store.saveTask(failedTask)
            }
            activeDownloaders.removeValue(forKey: taskId)
            onTasksChanged?()
        }
    }

    private func executeHLSDownload(task: DownloadTask) async {
        let taskId = task.id
        let hlsDownloader = HLSDownloader()
        activeHLSTasks[taskId] = hlsDownloader

        do {
            try await hlsDownloader.download(
                playlistURL: task.url,
                destinationFile: task.finalFilePath,
                tempDirectory: task.tempDirectory,
                onProgress: { [weak self] downloadedSegs, totalSegs, speed in
                    guard let self = self else { return }
                    if var t = try? self.store.getTask(id: taskId) {
                        t.downloadedBytes = Int64(downloadedSegs)
                        t.totalBytes = Int64(totalSegs)
                        t.speed = speed
                        try? self.store.saveTask(t)
                    }
                    self.onTaskProgressUpdated?(taskId, Int64(downloadedSegs), speed, [])
                }
            )

            if var completed = try? store.getTask(id: taskId) {
                completed.status = .completed
                completed.speed = 0
                try store.saveTask(completed)
            }
            activeHLSTasks.removeValue(forKey: taskId)
            onTasksChanged?()
        } catch {
            if var failed = try? store.getTask(id: taskId) {
                failed.status = .failed
                failed.errorMessage = error.localizedDescription
                failed.speed = 0
                try? store.saveTask(failed)
            }
            activeHLSTasks.removeValue(forKey: taskId)
            onTasksChanged?()
        }
    }

    public func pauseDownload(taskId: UUID) {
        if let downloader = activeDownloaders[taskId] {
            Task { await downloader.pause() }
        }
        activeTaskHandles[taskId]?.cancel()
        activeTaskHandles.removeValue(forKey: taskId)
        activeDownloaders.removeValue(forKey: taskId)

        if var task = getTask(id: taskId) {
            task.status = .paused
            task.speed = 0
            try? store.saveTask(task)
            onTasksChanged?()
        }
    }

    public func deleteTask(taskId: UUID) {
        pauseDownload(taskId: taskId)
        if let task = getTask(id: taskId) {
            try? FileManager.default.removeItem(at: task.tempDirectory)
            try? store.deleteTask(id: taskId)
            onTasksChanged?()
        }
    }
}
