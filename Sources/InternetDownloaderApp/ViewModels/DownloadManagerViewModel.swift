import Foundation
import SwiftUI
import AppKit
import DownloaderCore

public enum DownloadCategory: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case downloading = "Đang tải"
    case completed = "Hoàn tất"
    case paused = "Tạm dừng"
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

    private let manager = DownloadManager.shared
    private var clipboardTimer: Timer?
    private var lastSeenClipboardURL: String = ""

    public init() {
        refreshTasks()
        manager.startIPC()
        startClipboardMonitoring()

        manager.onTasksChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshTasks()
            }
        }

        manager.onTaskProgressUpdated = { [weak self] taskId, downloaded, speed, segments in
            Task { @MainActor in
                guard let self = self else { return }
                if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                    self.tasks[idx].downloadedBytes = downloaded
                    self.tasks[idx].speed = speed
                }
                if self.selectedTaskId == taskId {
                    self.selectedTaskSegments = segments
                }
            }
        }
    }

    public func startClipboardMonitoring() {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      (string.hasPrefix("http://") || string.hasPrefix("https://")),
                      string != self.lastSeenClipboardURL else { return }

                self.lastSeenClipboardURL = string
                let ext = URL(string: string)?.pathExtension.lowercased() ?? ""
                let autoDownloadExts = ["zip", "dmg", "pkg", "iso", "mp4", "mkv", "mp3", "pdf", "tar", "gz", "7z", "m3u8", "gif", "rar", "exe"]
                if autoDownloadExts.contains(ext) {
                    self.clipboardDetectedURL = string
                    self.showNewDownloadSheet = true
                }
            }
        }
    }

    public func refreshTasks() {
        self.tasks = manager.getAllTasks()
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
        case .video:
            return tasks.filter { ["mp4", "mkv", "mov", "avi", "webm", "ts", "m3u8"].contains(fileExt($0)) }
        case .audio:
            return tasks.filter { ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(fileExt($0)) }
        case .compressed:
            return tasks.filter { ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(fileExt($0)) }
        case .programs:
            return tasks.filter { ["dmg", "pkg", "iso", "app", "exe"].contains(fileExt($0)) }
        case .documents:
            return tasks.filter { ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt"].contains(fileExt($0)) }
        case .images:
            return tasks.filter { ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(fileExt($0)) }
        }
    }

    private func fileExt(_ task: DownloadTask) -> String {
        URL(fileURLWithPath: task.filename).pathExtension.lowercased()
    }

    public var selectedTask: DownloadTask? {
        guard let id = selectedTaskId else { return tasks.first }
        return tasks.first(where: { $0.id == id })
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

    public func deleteTask(_ id: UUID) {
        manager.deleteTask(taskId: id)
        if selectedTaskId == id {
            selectedTaskId = nil
            selectedTaskSegments = []
        }
        refreshTasks()
    }

    public func openFile(_ task: DownloadTask) {
        let path = task.finalFilePath
        NSWorkspace.shared.open(path)
    }

    public func revealInFinder(_ task: DownloadTask) {
        let path = task.finalFilePath
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }
}
