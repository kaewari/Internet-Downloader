import SwiftUI
import DownloaderCore

public struct MainWindow: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @State private var taskForRefreshAddress: DownloadTask? = nil

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            // Sidebar
            List(DownloadCategory.allCases, selection: $viewModel.selectedCategory) { category in
                NavigationLink(value: category) {
                    Label {
                        HStack {
                            Text(category.rawValue)
                            Spacer()
                            Text("\(count(for: category))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: category.iconName)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            VStack(spacing: 0) {
                // Task List
                if viewModel.filteredTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Không có tác vụ tải nào")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Button("Thêm liên kết tải mới") {
                            viewModel.showNewDownloadSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.filteredTasks) { task in
                            TaskRowView(
                                task: task,
                                isSelected: viewModel.selectedTaskId == task.id,
                                onPause: { viewModel.pauseTask(task.id) },
                                onResume: { viewModel.resumeTask(task.id) },
                                onDelete: { viewModel.deleteTask(task.id) },
                                onOpen: { viewModel.openFile(task) },
                                onReveal: { viewModel.revealInFinder(task) },
                                onRefreshAddress: { taskForRefreshAddress = task }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectTask(task.id)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }

                // Bottom IDM Segment Visualizer Panel
                if let selected = viewModel.selectedTask {
                    Divider()
                    SegmentVisualizerView(
                        segments: viewModel.selectedTaskSegments,
                        totalBytes: selected.totalBytes
                    )
                    .padding(8)
                }
            }
            .navigationTitle("Internet Downloader")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { viewModel.showNewDownloadSheet = true }) {
                        Label("Thêm URL", systemImage: "plus")
                    }
                    .help("Thêm liên kết tải mới")

                    Button(action: { viewModel.pauseAllTasks() }) {
                        Label("Tạm dừng tất cả", systemImage: "pause.circle")
                    }
                    .help("Tạm dừng tất cả tác vụ đang tải")
                    .disabled(!viewModel.tasks.contains(where: { $0.status == .downloading || $0.status == .pending }))

                    Button(action: { viewModel.resumeAllTasks() }) {
                        Label("Tiếp tục tất cả", systemImage: "play.circle")
                    }
                    .help("Tiếp tục tất cả tác vụ đã tạm dừng hoặc bị lỗi")
                    .disabled(!viewModel.tasks.contains(where: { $0.status == .paused || $0.status == .failed || $0.status == .pending }))

                    Button(action: { viewModel.performToolbarCleanup() }) {
                        Label("Dọn dẹp danh sách", systemImage: "trash.slash")
                    }
                    .help("Dọn dẹp tác vụ hoàn tất/lỗi hoặc xóa tác vụ đang chọn")
                    .disabled(viewModel.tasks.isEmpty)
                }
            }
        }
        .sheet(isPresented: $viewModel.showNewDownloadSheet) {
            NewDownloadDialog(
                isPresented: $viewModel.showNewDownloadSheet,
                initialURL: viewModel.clipboardDetectedURL
            ) { url, filename, folder, segs in
                viewModel.clipboardDetectedURL = nil
                viewModel.addNewDownload(url: url, filename: filename, destinationFolder: folder, segments: segs)
            }
        }
        .sheet(item: $taskForRefreshAddress) { task in
            RefreshAddressDialog(
                isPresented: Binding(
                    get: { taskForRefreshAddress != nil },
                    set: { if !$0 { taskForRefreshAddress = nil } }
                ),
                task: task
            ) { newURL, newReferrer in
                viewModel.updateTaskURL(taskId: task.id, newURL: newURL, newReferrer: newReferrer)
            }
        }
        .sheet(item: $viewModel.pendingConfirmationTask) { task in
            DownloadConfirmationDialog(
                task: task,
                onStart: { filename, folder, segs, probedSize in
                    viewModel.confirmAndStartTask(taskId: task.id, filename: filename, destinationFolder: folder, segments: segs, totalBytes: probedSize)
                },
                onCancel: {
                    viewModel.cancelPendingConfirmation(task.id)
                }
            )
        }
    }

    private func count(for category: DownloadCategory) -> Int {
        switch category {
        case .all: return viewModel.tasks.count
        case .downloading: return viewModel.tasks.filter { $0.status == .downloading || $0.status == .pending }.count
        case .completed: return viewModel.tasks.filter { $0.status == .completed }.count
        case .paused: return viewModel.tasks.filter { $0.status == .paused }.count
        case .failed: return viewModel.tasks.filter { $0.status == .failed }.count
        case .video: return viewModel.tasks.filter { ["mp4", "mkv", "mov", "avi", "webm", "ts", "m3u8"].contains(fileExt($0)) }.count
        case .audio: return viewModel.tasks.filter { ["mp3", "m4a", "flac", "wav", "aac", "ogg"].contains(fileExt($0)) }.count
        case .compressed: return viewModel.tasks.filter { ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(fileExt($0)) }.count
        case .programs: return viewModel.tasks.filter { ["dmg", "pkg", "iso", "app", "exe"].contains(fileExt($0)) }.count
        case .documents: return viewModel.tasks.filter { ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt"].contains(fileExt($0)) }.count
        case .images: return viewModel.tasks.filter { ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(fileExt($0)) }.count
        }
    }

    private func fileExt(_ task: DownloadTask) -> String {
        URL(fileURLWithPath: task.filename).pathExtension.lowercased()
    }
}
