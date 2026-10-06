import Foundation
import SwiftUI
import AppKit
import DownloaderCore

public enum DownloadCategory: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case downloading = "Đang tải"
    case completed = "Hoàn tất"
    case paused = "Tạm dừng"

    public var id: String { rawValue }
    public var iconName: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .paused: return "pause.circle"
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

    private let manager = DownloadManager.shared

    public init() {
        refreshTasks()
        manager.startIPC()

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
        }
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
