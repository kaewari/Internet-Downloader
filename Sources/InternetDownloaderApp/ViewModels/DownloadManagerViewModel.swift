import Foundation
import SwiftUI
import AppKit
import UserNotifications
import DownloaderCore

public enum DownloadCategory: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case downloading = "Đang tải"
    case completed = "Hoàn tất"
    case paused = "Tạm dừng"
    case failed = "Lỗi"
    case video = "Video"
    case audio = "Nhạc & Audio"
    case compressed = "Tệp nén"
    case programs = "Ứng dụng"
    case documents = "Tài liệu"
    case images = "Hình ảnh & GIF"

    public var id: String { rawValue }
    public var iconName: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .failed: return "xmark.octagon"
        case .video: return "film"
        case .audio: return "music.note"
        case .compressed: return "doc.zipper"
        case .programs: return "shippingbox"
        case .documents: return "doc.richtext"
        case .images: return "photo"
        }
    }
}

/// Timer clipboard chạy trên runloop chính nhưng được sở hữu bởi object
/// non-isolated, để deinit của ViewModel (@MainActor) không phải chạm vào
/// state isolated mà timer vẫn được invalidate khi ViewModel giải phóng (C-F13).
private final class ClipboardWatcher {
    var timer: Timer?
    var onFire: (() -> Void)?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.onFire?()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

@MainActor
public final class DownloadManagerViewModel: ObservableObject {
    @Published public var tasks: [DownloadTask] = []
    @Published public var selectedCategory: DownloadCategory = .all
    @Published public var selectedTaskId: UUID?
    @Published public var selectedTaskSegments: [DownloadSegment] = []
    @Published public var showNewDownloadSheet: Bool = false
    @Published public var clipboardDetectedURL: String?
    @Published public var pendingConfirmationTask: DownloadTask? = nil
    /// Banner lỗi tập trung thay cho print() (C-F6). View hiển thị + nút đóng.
    @Published public var errorBanner: String? = nil

    // MARK: - Derived caches (C-F12, 1 pass)

    /// Count theo từng category, tính 1 pass sau mỗi lần tasks đổi.
    @Published public private(set) var cachedCounts: [DownloadCategory: Int] = [:]
    /// Danh sách đã filter theo tasks + selectedCategory.
    @Published public private(set) var cachedFilteredTasks: [DownloadTask] = []
    @Published public private(set) var hasCompletedOrFailed: Bool = false
    /// Đọc từ tasks đã throttle 3Hz — MenuBarExtra dùng các giá trị này (C-F15).
    @Published public private(set) var cachedOverallProgress: Double = 0
    @Published public private(set) var cachedAggregateSpeed: Double = 0
    @Published public private(set) var cachedDownloadingCount: Int = 0

    public func cachedCount(for category: DownloadCategory) -> Int {
        cachedCounts[category] ?? 0
    }

    private let manager = DownloadManager.shared
    private let clipboardWatcher = ClipboardWatcher()
    private var lastSeenClipboardURL: String = ""

    // MARK: - Progress throttle (C-F1)

    private struct PendingProgress {
        var downloaded: Int64
        var total: Int64
        var downloadedSegs: Int
        var totalSegs: Int
        var speed: Double
        var segments: [DownloadSegment]
    }

    /// Tick engine có thể tới hàng chục lần/giây; chỉ publish ra UI tối đa 3Hz.
    private static let progressThrottleInterval: TimeInterval = 1.0 / 3.0
    private static let progressByteThreshold: Int64 = 64 * 1024
    private static let progressSpeedThreshold: Double = 32 * 1024
    private var pendingProgress: [UUID: PendingProgress] = [:]
    private var lastProgressPublish = Date.distantPast
    private var progressFlushTask: Task<Void, Never>?

    // MARK: - Single updater (C-F1 + C-F14)

    /// Mọi callback engine đều đi qua 2 pipeline này thay vì 6 Task fire-forget
    /// rời rạc: refresh pipeline (hủy task cũ khi tick mới) và progress pipeline.
    private var refreshTask: Task<Void, Never>?

    /// Id xác nhận đã xử lý (Start/Cancel/ESC) để sheet onDismiss không xóa nhầm (C-F8).
    private var confirmationHandledIds: Set<UUID> = []

    // MARK: - Notification coalescing (C-F5)

    private var notificationBurst: [String] = []
    private var notificationBurstTask: Task<Void, Never>?

    public init() {
        refreshDerivedCaches()
        refreshTasks()
        manager.startIPC()
        startClipboardMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        manager.onTasksChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.enqueueRefresh() }
        }

        manager.onDownloadConfirmationRequested = { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.enqueueRefresh()
                self.pendingConfirmationTask = task
                NSSound(named: "Glass")?.play()
                Self.activateIfNeeded()
            }
        }

        manager.onDownloadStarted = { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.enqueueRefresh()
                self.selectedTaskId = task.id
                NSSound(named: "Glass")?.play()
                Self.activateIfNeeded()
                self.queueNotification("Bắt đầu tải: \(task.filename)")
            }
        }

        manager.onDownloadCompleted = { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.enqueueRefresh()
                NSSound(named: "Hero")?.play()
                self.queueNotification("Hoàn tất tải xuống: \(task.filename)")
            }
        }

        manager.onDownloadFailed = { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.enqueueRefresh()
                NSSound(named: "Basso")?.play()
                let reason = (task.errorMessage?.isEmpty ?? true) ? "Không rõ nguyên nhân" : (task.errorMessage ?? "Không rõ nguyên nhân")
                self.queueNotification("Tải thất bại: \(task.filename) — \(reason)")
            }
        }

        manager.onTaskProgressUpdated = { [weak self] taskId, downloaded, total, downloadedSegs, totalSegs, speed, segments in
            Task { @MainActor [weak self] in
                self?.coalesceProgress(
                    taskId: taskId, downloaded: downloaded, total: total,
                    downloadedSegs: downloadedSegs, totalSegs: totalSegs,
                    speed: speed, segments: segments
                )
            }
        }
    }

    deinit {
        // Không chạm state @MainActor ở đây; timer đã do ClipboardWatcher tự
        // invalidate trong deinit của nó. Chỉ gỡ observer hệ thống.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - App active (C-F13)

    @objc private func handleAppWillResignActive() {
        Task { @MainActor [weak self] in self?.stopClipboardMonitoring() }
    }

    @objc private func handleAppDidBecomeActive() {
        Task { @MainActor [weak self] in self?.startClipboardMonitoring() }
    }

    // MARK: - Clipboard

    public func startClipboardMonitoring() {
        lastSeenClipboardURL = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        clipboardWatcher.onFire = { [weak self] in
            Task { @MainActor [weak self] in self?.pollClipboard() }
        }
        clipboardWatcher.start()
    }

    public func stopClipboardMonitoring() {
        clipboardWatcher.stop()
    }

    private func pollClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (string.hasPrefix("http://") || string.hasPrefix("https://")),
              string != lastSeenClipboardURL else { return }

        lastSeenClipboardURL = string
        guard let normURL = URLNormalizer.normalize(string) else { return }
        let ext = normURL.pathExtension.lowercased()
        let autoDownloadExts = ["zip", "dmg", "pkg", "iso", "mp4", "mkv", "mp3", "pdf", "tar", "gz", "7z", "m3u8", "gif", "rar", "exe", "webm", "flv"]
        if autoDownloadExts.contains(ext) || URLNormalizer.isVideoPlatformURL(normURL) {
            clipboardDetectedURL = normURL.absoluteString
            showNewDownloadSheet = true
        }
    }

    // MARK: - Refresh (C-F3: nặng chạy background, diff-update)

    /// Entry duy nhất cho mọi yêu cầu refresh: hủy task cũ khi tick mới (C-F14),
    /// phần nặng (fileExists, detectExtension, moveItem, saveTask) chạy detached.
    public func refreshTasks() {
        enqueueRefresh()
    }

    private func enqueueRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let reconciled = await Task.detached(priority: .utility) {
                var all = DownloadManager.shared.getAllTasks()
                DownloadManagerViewModel.reconcileFilenamesOffMain(allTasks: &all)
                return all
            }.value
            guard !Task.isCancelled else { return }
            self.applyTasksDiff(reconciled)
            if let sel = self.selectedTaskId {
                self.selectedTaskSegments = self.manager.getSegments(for: sel)
            }
        }
    }

    /// Chạy OFF MainActor (nonisolated): không chạm self, chỉ dùng local + engine.
    nonisolated private static func reconcileFilenamesOffMain(allTasks: inout [DownloadTask]) {
        let fm = FileManager.default
        let store = DownloadManager.shared.store
        for i in 0..<allTasks.count {
            var task = allTasks[i]
            let ext = (task.filename as NSString).pathExtension
            if ext.isEmpty || FileTypeDetector.isOpaqueIdentifier(task.filename) {
                // 1. Try URL query extraction
                if let extracted = FileTypeDetector.extractFilename(from: task.url) {
                    let oldPath = task.finalFilePath
                    task.filename = extracted
                    let newPath = task.finalFilePath
                    if task.status == .completed && fm.fileExists(atPath: oldPath.path) && oldPath != newPath {
                        try? fm.moveItem(at: oldPath, to: newPath)
                    }
                    try? store.saveTask(task)
                    allTasks[i] = task
                } else if task.status == .completed,
                          fm.fileExists(atPath: task.finalFilePath.path),
                          let detectedExt = FileTypeDetector.detectExtension(fileURL: task.finalFilePath) {
                    // 2. Try disk magic bytes (only after task is completed)
                    let oldPath = task.finalFilePath
                    let baseName = (task.filename as NSString).deletingPathExtension
                    let newFilename = ext.isEmpty ? "\(task.filename).\(detectedExt)" : "\(baseName).\(detectedExt)"
                    let newPath = task.destinationFolder.appendingPathComponent(newFilename)
                    if oldPath != newPath {
                        try? fm.moveItem(at: oldPath, to: newPath)
                    }
                    task.filename = newFilename
                    try? store.saveTask(task)
                    allTasks[i] = task
                }
            }
        }
    }

    /// Diff-update: giữ nguyên thứ tự/identity khi danh sách không đổi (C-F3).
    private func applyTasksDiff(_ all: [DownloadTask]) {
        if tasks.count == all.count && tasks.map(\.id) == all.map(\.id) {
            for (i, t) in all.enumerated() where tasks[i].id == t.id {
                tasks[i] = t
            }
        } else {
            tasks = all
        }
        if let sel = selectedTaskId, !tasks.contains(where: { $0.id == sel }) {
            selectedTaskId = nil
            selectedTaskSegments = []
        }
        refreshDerivedCaches()
    }

    // MARK: - Progress coalescing (C-F1, 3Hz)

    private func coalesceProgress(taskId: UUID, downloaded: Int64, total: Int64,
                                  downloadedSegs: Int, totalSegs: Int,
                                  speed: Double, segments: [DownloadSegment]) {
        pendingProgress[taskId] = PendingProgress(
            downloaded: downloaded, total: total,
            downloadedSegs: downloadedSegs, totalSegs: totalSegs,
            speed: speed, segments: segments
        )
        let now = Date()
        if now.timeIntervalSince(lastProgressPublish) >= Self.progressThrottleInterval {
            flushProgress()
        } else {
            scheduleProgressFlush()
        }
    }

    private func scheduleProgressFlush() {
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 333_000_000)
            guard let self = self else { return }
            self.progressFlushTask = nil
            self.flushProgress()
        }
    }

    private func flushProgress() {
        guard !pendingProgress.isEmpty else {
            lastProgressPublish = Date()
            return
        }
        lastProgressPublish = Date()
        let drained = pendingProgress
        pendingProgress.removeAll(keepingCapacity: true)
        let visibleId = selectedTaskId ?? selectedTask?.id

        for (taskId, p) in drained {
            guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { continue }
            let old = tasks[idx]
            if taskId == visibleId {
                // Task đang hiển thị (row + segment visualizer): luôn publish.
                if p.downloaded >= old.downloadedBytes || old.status != .downloading {
                    tasks[idx].downloadedBytes = p.downloaded
                }
                if p.total > 0 { tasks[idx].totalBytes = p.total }
                if p.downloadedSegs > 0 { tasks[idx].downloadedSegmentsCount = p.downloadedSegs }
                if p.totalSegs > 0 { tasks[idx].segmentsCount = p.totalSegs }
                tasks[idx].speed = p.speed
                selectedTaskSegments = p.segments
            } else {
                // Task nền: chỉ publish khi delta đáng kể (giảm re-render List).
                let byteDelta = p.downloaded >= old.downloadedBytes ? p.downloaded - old.downloadedBytes : Int64.max
                let speedDelta = abs(p.speed - old.speed)
                let metaChanged = (p.total > 0 && p.total != old.totalBytes)
                    || (p.totalSegs > 0 && p.totalSegs != old.segmentsCount)
                    || (p.downloadedSegs > 0 && p.downloadedSegs != old.downloadedSegmentsCount)
                guard byteDelta > Self.progressByteThreshold
                    || speedDelta > Self.progressSpeedThreshold
                    || metaChanged else { continue }
                if p.downloaded >= old.downloadedBytes {
                    tasks[idx].downloadedBytes = p.downloaded
                }
                if p.total > 0 { tasks[idx].totalBytes = p.total }
                if p.downloadedSegs > 0 { tasks[idx].downloadedSegmentsCount = p.downloadedSegs }
                if p.totalSegs > 0 { tasks[idx].segmentsCount = p.totalSegs }
                tasks[idx].speed = p.speed
            }
        }
    }

    // MARK: - Derived caches (C-F12)

    private func refreshDerivedCaches() {
        var counts: [DownloadCategory: Int] = Dictionary(
            uniqueKeysWithValues: DownloadCategory.allCases.map { ($0, 0) }
        )
        for task in tasks {
            counts[.all, default: 0] += 1
            switch task.status {
            case .downloading, .pending: counts[.downloading, default: 0] += 1
            case .completed: counts[.completed, default: 0] += 1
            case .paused: counts[.paused, default: 0] += 1
            case .failed: counts[.failed, default: 0] += 1
            case .assembling: counts[.downloading, default: 0] += 1
            case .needsConfirmation: break
            }
            if let cat = FileTypeHelper.category(for: task.filename) {
                counts[cat, default: 0] += 1
            }
        }
        cachedCounts = counts
        cachedFilteredTasks = makeFilteredTasks()
        hasCompletedOrFailed = tasks.contains { $0.status == .completed || $0.status == .failed }

        let active = tasks.filter { $0.status == .downloading || $0.status == .pending || $0.status == .assembling }
        cachedDownloadingCount = tasks.filter { $0.status == .downloading }.count
        cachedAggregateSpeed = tasks
            .filter { $0.status == .downloading }
            .reduce(0) { $0 + $1.speed }
        var done: Int64 = 0
        var total: Int64 = 0
        for t in active where t.totalBytes > 0 {
            done += min(max(0, t.downloadedBytes), t.totalBytes)
            total += t.totalBytes
        }
        cachedOverallProgress = total > 0 ? Double(done) / Double(total) : 0
    }

    private func makeFilteredTasks() -> [DownloadTask] {
        switch selectedCategory {
        case .all:
            return tasks
        case .downloading:
            return tasks.filter { $0.status == .downloading || $0.status == .pending || $0.status == .assembling }
        case .completed:
            return tasks.filter { $0.status == .completed }
        case .paused:
            return tasks.filter { $0.status == .paused }
        case .failed:
            return tasks.filter { $0.status == .failed }
        case .video:
            return tasks.filter { FileTypeHelper.videoExtensions.contains(FileTypeHelper.fileExtension(of: $0.filename)) }
        case .audio:
            return tasks.filter { FileTypeHelper.audioExtensions.contains(FileTypeHelper.fileExtension(of: $0.filename)) }
        case .compressed:
            return tasks.filter { FileTypeHelper.compressedExtensions.contains(FileTypeHelper.fileExtension(of: $0.filename)) }
        case .programs:
            return tasks.filter { FileTypeHelper.programExtensions.contains(FileTypeHelper.fileExtension(of: $0.filename)) }
        case .documents:
            return tasks.filter { FileTypeHelper.documentExtensions.contains(FileTypeHelper.fileExtension(of: $0.filename)) }
        case .images:
            return tasks.filter { FileTypeHelper.imageExtensions.contains(FileTypeHelper.fileExtension(of: $0.filename)) }
        }
    }

    public var filteredTasks: [DownloadTask] {
        cachedFilteredTasks
    }

    public var selectedTask: DownloadTask? {
        if let id = selectedTaskId, let task = tasks.first(where: { $0.id == id }) {
            return task
        }
        return tasks.first(where: { $0.status == .downloading }) ?? tasks.first
    }

    public func selectTask(_ id: UUID) {
        self.selectedTaskId = id
        self.selectedTaskSegments = manager.getSegments(for: id)
    }

    // MARK: - Error banner (C-F6)

    public func dismissErrorBanner() {
        errorBanner = nil
    }

    // MARK: - Mutations

    public func addNewDownload(url: URL, filename: String, destinationFolder: URL, segments: Int = 8) {
        do {
            let task = try manager.createNewTask(
                url: url,
                filename: filename,
                destinationFolder: destinationFolder,
                segmentsCount: segments
            )
            manager.startDownload(taskId: task.id)
            refreshTasks()
            selectTask(task.id)
        } catch {
            errorBanner = "Không thêm được lượt tải: \(error.localizedDescription)"
        }
    }

    public func pauseTask(_ id: UUID) {
        manager.pauseDownload(taskId: id)
        refreshTasks()
    }

    public func resumeTask(_ id: UUID) {
        manager.startDownload(taskId: id)
        refreshTasks()
    }

    public func confirmAndStartTask(taskId: UUID, filename: String, destinationFolder: URL, segments: Int, totalBytes: Int64? = nil) {
        confirmationHandledIds.insert(taskId)
        manager.updateTaskSettings(taskId: taskId, filename: filename, destinationFolder: destinationFolder, segmentsCount: segments, totalBytes: totalBytes)
        manager.startDownload(taskId: taskId)
        refreshTasks()
        selectTask(taskId)
        self.pendingConfirmationTask = nil
    }

    public func cancelPendingConfirmation(_ taskId: UUID) {
        confirmationHandledIds.insert(taskId)
        manager.deleteTask(taskId: taskId)
        if selectedTaskId == taskId {
            selectedTaskId = nil
            selectedTaskSegments = []
        }
        if pendingConfirmationTask?.id == taskId {
            pendingConfirmationTask = nil
        }
        refreshTasks()
    }

    /// Sheet needsConfirmation bị dismiss (ESC) mà chưa Start/Cancel → dọn orphan (C-F8).
    public func handleConfirmationDismiss(taskId: UUID) {
        if confirmationHandledIds.contains(taskId) {
            confirmationHandledIds.remove(taskId)
            return
        }
        cancelPendingConfirmation(taskId)
    }

    public func deleteTask(_ id: UUID) {
        manager.deleteTask(taskId: id)
        if selectedTaskId == id {
            selectedTaskId = nil
            selectedTaskSegments = []
        }
        if pendingConfirmationTask?.id == id {
            pendingConfirmationTask = nil
        }
        refreshTasks()
    }

    public func pauseAllTasks() {
        manager.pauseAllTasks()
        refreshTasks()
    }

    public func resumeAllTasks() {
        manager.resumeAllTasks()
        refreshTasks()
    }

    public func clearFailedTasks() {
        do {
            try manager.clearFailedTasks()
            refreshTasks()
            if let sel = selectedTaskId, !tasks.contains(where: { $0.id == sel }) {
                selectedTaskId = nil
                selectedTaskSegments = []
            }
        } catch {
            errorBanner = "Không xóa được task lỗi: \(error.localizedDescription)"
        }
    }

    public func clearCompletedAndFailedTasks() {
        do {
            try manager.clearCompletedAndFailedTasks()
            refreshTasks()
            if let sel = selectedTaskId, !tasks.contains(where: { $0.id == sel }) {
                selectedTaskId = nil
                selectedTaskSegments = []
            }
        } catch {
            errorBanner = "Không dọn dẹp được danh sách: \(error.localizedDescription)"
        }
    }

    /// Thử lại task video bị mất tiếng bằng yt-dlp (URL trang gốc nếu có).
    public func retryAudioRepair(_ id: UUID) {
        manager.retryAudioRepair(taskId: id)
        refreshTasks()
        selectTask(id)
    }

    /// Đưa mọi cửa sổ chính lên trước khi hiện sheet xác nhận / bắt đầu tải.
    /// Trước đây chỉ gọi makeKeyAndOrderFront cho cửa sổ đầu tiên; nếu app đang
    /// ở Space khác hoặc cửa sổ bị che, người dùng bấm "Tải video này" mà không
    /// thấy gì.
    private static func bringWindowsToFront() {
        for window in NSApp.windows where window.canBecomeKey && !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }
        if let main = NSApp.windows.first(where: { $0.styleMask.contains([.titled, .closable]) && !($0 is NSPanel) }) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    /// Chỉ cướp focus khi app chưa active (C-F5). Khi đã active, chỉ đưa cửa sổ lên.
    private static func activateIfNeeded() {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        bringWindowsToFront()
    }

    public func updateTaskURL(taskId: UUID, newURL: URL, newReferrer: String?) {
        do {
            try manager.updateTaskURL(taskId: taskId, newURL: newURL, newReferrer: newReferrer)
            resumeTask(taskId)
        } catch {
            errorBanner = "Không cập nhật được địa chỉ tải: \(error.localizedDescription)"
        }
    }

    public func openFile(_ task: DownloadTask) {
        var path = task.finalFilePath
        if !FileManager.default.fileExists(atPath: path.path) {
            let currentExt = (task.filename as NSString).pathExtension
            if currentExt.isEmpty {
                for candidateExt in ["dmg", "pkg", "zip", "pdf", "mp4", "sqlite", "exe"] {
                    let candURL = task.destinationFolder.appendingPathComponent("\(task.filename).\(candidateExt)")
                    if FileManager.default.fileExists(atPath: candURL.path) {
                        path = candURL
                        break
                    }
                }
            }
        }

        if FileManager.default.fileExists(atPath: path.path) && (path.pathExtension.isEmpty || FileTypeDetector.isOpaqueIdentifier(path.lastPathComponent)) {
            if let detectedExt = FileTypeDetector.detectExtension(fileURL: path) {
                let baseName = (path.lastPathComponent as NSString).deletingPathExtension
                let newFilename = path.pathExtension.isEmpty ? "\(path.lastPathComponent).\(detectedExt)" : "\(baseName).\(detectedExt)"
                let newPath = task.destinationFolder.appendingPathComponent(newFilename)
                if newPath != path {
                    try? FileManager.default.moveItem(at: path, to: newPath)
                    path = newPath
                }

                if var updatedTask = manager.getTask(id: task.id) {
                    updatedTask.filename = newFilename
                    try? manager.store.saveTask(updatedTask)
                    refreshTasks()
                }
            }
        }

        NSWorkspace.shared.open(path)
    }

    public func revealInFinder(_ task: DownloadTask) {
        var path = task.finalFilePath
        if !FileManager.default.fileExists(atPath: path.path) {
            let currentExt = (task.filename as NSString).pathExtension
            if currentExt.isEmpty {
                for candidateExt in ["dmg", "pkg", "zip", "pdf", "mp4", "sqlite", "exe"] {
                    let candURL = task.destinationFolder.appendingPathComponent("\(task.filename).\(candidateExt)")
                    if FileManager.default.fileExists(atPath: candURL.path) {
                        path = candURL
                        break
                    }
                }
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    // MARK: - Notifications (C-F5: gộp burst thành 1 notification)

    /// Gom các sự kiện dồn dập (nhiều task xong cùng lúc) thành 1 notification duy nhất.
    private func queueNotification(_ body: String) {
        notificationBurst.append(body)
        notificationBurstTask?.cancel()
        notificationBurstTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            self.notificationBurstTask = nil
            self.flushNotifications()
        }
    }

    private func flushNotifications() {
        guard !notificationBurst.isEmpty else { return }
        let bodies = notificationBurst
        notificationBurst.removeAll(keepingCapacity: true)
        if bodies.count == 1 {
            sendSystemNotification(title: "Internet Downloader", body: bodies[0])
        } else {
            let head = bodies.prefix(3).joined(separator: "\n")
            let tail = bodies.count > 3 ? "\n…và \(bodies.count - 3) cập nhật khác" : ""
            sendSystemNotification(title: "Internet Downloader (\(bodies.count) cập nhật)", body: head + tail)
        }
    }

    private func sendSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
