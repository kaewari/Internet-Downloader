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

@MainActor
public final class DownloadManagerViewModel: ObservableObject {
    @Published public var tasks: [DownloadTask] = []
    @Published public var selectedCategory: DownloadCategory = .all
    @Published public var selectedTaskId: UUID?
    @Published public var selectedTaskSegments: [DownloadSegment] = []
    @Published public var showNewDownloadSheet: Bool = false
    @Published public var clipboardDetectedURL: String?
    @Published public var pendingConfirmationTask: DownloadTask? = nil

    private let manager = DownloadManager.shared
    private var clipboardTimer: Timer?
    private var lastSeenClipboardURL: String = ""

    public init() {
        refreshTasks()
        manager.startIPC()
        startClipboardMonitoring()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        manager.onTasksChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshTasks()
            }
        }

        manager.onDownloadConfirmationRequested = { [weak self] task in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshTasks()
                self.pendingConfirmationTask = task
                NSSound(named: "Glass")?.play()
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !$0.isSheet && !($0 is NSPanel) }) ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        manager.onDownloadStarted = { [weak self] task in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshTasks()
                self.selectedTaskId = task.id
                NSSound(named: "Glass")?.play()
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !$0.isSheet && !($0 is NSPanel) }) ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
                self.sendSystemNotification(title: "Internet Downloader", body: "Bắt đầu tải: \(task.filename)")
            }
        }

        manager.onDownloadCompleted = { [weak self] task in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshTasks()
                NSSound(named: "Hero")?.play()
                self.sendSystemNotification(title: "Internet Downloader", body: "Hoàn tất tải xuống: \(task.filename)")
            }
        }

        manager.onTaskProgressUpdated = { [weak self] taskId, downloaded, total, downloadedSegs, totalSegs, speed, segments in
            Task { @MainActor in
                guard let self = self else { return }
                if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                    if downloaded >= self.tasks[idx].downloadedBytes || self.tasks[idx].status != .downloading {
                        self.tasks[idx].downloadedBytes = downloaded
                    }
                    if total > 0 {
                        self.tasks[idx].totalBytes = total
                    }
                    if downloadedSegs > 0 {
                        self.tasks[idx].downloadedSegmentsCount = downloadedSegs
                    }
                    if totalSegs > 0 {
                        self.tasks[idx].segmentsCount = totalSegs
                    }
                    self.tasks[idx].speed = speed
                }
                if self.selectedTaskId == taskId || self.selectedTaskId == nil || self.selectedTask?.id == taskId {
                    self.selectedTaskSegments = segments
                }
            }
        }
    }

    public func startClipboardMonitoring() {
        lastSeenClipboardURL = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      (string.hasPrefix("http://") || string.hasPrefix("https://")),
                      string != self.lastSeenClipboardURL else { return }

                self.lastSeenClipboardURL = string
                guard let normURL = URLNormalizer.normalize(string) else { return }
                let ext = normURL.pathExtension.lowercased()
                let autoDownloadExts = ["zip", "dmg", "pkg", "iso", "mp4", "mkv", "mp3", "pdf", "tar", "gz", "7z", "m3u8", "gif", "rar", "exe", "webm", "flv"]
                if autoDownloadExts.contains(ext) || URLNormalizer.isVideoPlatformURL(normURL) {
                    self.clipboardDetectedURL = normURL.absoluteString
                    self.showNewDownloadSheet = true
                }
            }
        }
    }

    public func refreshTasks() {
        var allTasks = manager.getAllTasks()
        for i in 0..<allTasks.count {
            var task = allTasks[i]
            let ext = (task.filename as NSString).pathExtension
            if ext.isEmpty || FileTypeDetector.isOpaqueIdentifier(task.filename) {
                // 1. Try URL query extraction
                if let extracted = FileTypeDetector.extractFilename(from: task.url) {
                    let oldPath = task.finalFilePath
                    task.filename = extracted
                    let newPath = task.finalFilePath
                    if task.status == .completed && FileManager.default.fileExists(atPath: oldPath.path) && oldPath != newPath {
                        try? FileManager.default.moveItem(at: oldPath, to: newPath)
                    }
                    try? manager.store.saveTask(task)
                    allTasks[i] = task
                } else if task.status == .completed,
                          FileManager.default.fileExists(atPath: task.finalFilePath.path),
                          let detectedExt = FileTypeDetector.detectExtension(fileURL: task.finalFilePath) {
                    // 2. Try disk magic bytes (only after task is completed)
                    let oldPath = task.finalFilePath
                    let baseName = (task.filename as NSString).deletingPathExtension
                    let newFilename = ext.isEmpty ? "\(task.filename).\(detectedExt)" : "\(baseName).\(detectedExt)"
                    let newPath = task.destinationFolder.appendingPathComponent(newFilename)
                    if oldPath != newPath {
                        try? FileManager.default.moveItem(at: oldPath, to: newPath)
                    }
                    task.filename = newFilename
                    try? manager.store.saveTask(task)
                    allTasks[i] = task
                }
            }
        }
        self.tasks = allTasks
        if let sel = selectedTaskId {
            self.selectedTaskSegments = manager.getSegments(for: sel)
        }
    }

    public var filteredTasks: [DownloadTask] {
        switch selectedCategory {
        case .all:
            return tasks
        case .downloading:
            return tasks.filter { $0.status == .downloading || $0.status == .pending }
        case .completed:
            return tasks.filter { $0.status == .completed }
        case .paused:
            return tasks.filter { $0.status == .paused }
        case .failed:
            return tasks.filter { $0.status == .failed }
        case .video:
            return tasks.filter { ["mp4", "mkv", "mov", "avi", "webm", "ts", "m3u8"].contains(fileExt($0)) }
        case .audio:
            return tasks.filter { ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(fileExt($0)) }
        case .compressed:
            return tasks.filter { ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst"].contains(fileExt($0)) }
        case .programs:
            return tasks.filter { ["dmg", "pkg", "iso", "app", "exe", "msi", "deb", "rpm", "appimage"].contains(fileExt($0)) }
        case .documents:
            return tasks.filter { ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "rtf"].contains(fileExt($0)) }
        case .images:
            return tasks.filter { ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(fileExt($0)) }
        }
    }

    private func fileExt(_ task: DownloadTask) -> String {
        URL(fileURLWithPath: task.filename).pathExtension.lowercased()
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
            print("Failed to add download: \(error)")
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
        manager.updateTaskSettings(taskId: taskId, filename: filename, destinationFolder: destinationFolder, segmentsCount: segments, totalBytes: totalBytes)
        manager.startDownload(taskId: taskId)
        refreshTasks()
        selectTask(taskId)
        self.pendingConfirmationTask = nil
    }

    public func cancelPendingConfirmation(_ taskId: UUID) {
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
            print("Failed to clear failed tasks: \(error)")
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
            print("Failed to clear completed and failed tasks: \(error)")
        }
    }

    public func performToolbarCleanup() {
        if tasks.contains(where: { $0.status == .completed || $0.status == .failed }) {
            clearCompletedAndFailedTasks()
        } else if let target = selectedTask {
            deleteTask(target.id)
        }
    }

    public func updateTaskURL(taskId: UUID, newURL: URL, newReferrer: String?) {
        do {
            try manager.updateTaskURL(taskId: taskId, newURL: newURL, newReferrer: newReferrer)
            resumeTask(taskId)
        } catch {
            print("Failed to update task URL: \(error)")
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

    private func sendSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
