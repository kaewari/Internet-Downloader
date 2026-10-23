import SwiftUI
import DownloaderCore

public struct MainWindow: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @State private var taskForRefreshAddress: DownloadTask? = nil
    @State private var showDeleteSelectedConfirm: Bool = false
    /// Id của sheet needsConfirmation đang hiển thị, để onDismiss dọn orphan (C-F8).
    @State private var presentedConfirmationId: UUID? = nil

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            // Sidebar (count đọc từ cache 1-pass, C-F12)
            List(DownloadCategory.allCases, selection: $viewModel.selectedCategory) { category in
                NavigationLink(value: category) {
                    Label {
                        HStack {
                            Text(category.rawValue)
                            Spacer()
                            Text("\(viewModel.cachedCount(for: category))")
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
                // Error banner tập trung (C-F6)
                if let banner = viewModel.errorBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(banner)
                            .font(.callout)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.dismissErrorBanner()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Đóng thông báo lỗi")
                        .accessibilityLabel("Đóng thông báo lỗi")
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(8)
                    .padding([.top, .horizontal], 8)
                }

                // Task List (C-F10: List(selection:) native thay onTapGesture)
                if viewModel.cachedFilteredTasks.isEmpty {
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
                    List(selection: $viewModel.selectedTaskId) {
                        ForEach(viewModel.cachedFilteredTasks) { task in
                            TaskRowView(
                                task: task,
                                isSelected: viewModel.selectedTaskId == task.id,
                                onPause: { viewModel.pauseTask(task.id) },
                                onResume: { viewModel.resumeTask(task.id) },
                                onDelete: { viewModel.deleteTask(task.id) },
                                onOpen: { viewModel.openFile(task) },
                                onReveal: { viewModel.revealInFinder(task) },
                                onRefreshAddress: { taskForRefreshAddress = task },
                                onRetryAudio: { viewModel.retryAudioRepair(task.id) }
                            )
                            .tag(task.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .onChange(of: viewModel.selectedTaskId) { newId in
                        // Native selection (chuột/bàn phím/VoiceOver) → nạp segments.
                        if let id = newId {
                            viewModel.selectTask(id)
                        }
                    }
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

                    // C-F7: tách nút Dọn dẹp 2 nghĩa thành 2 action rõ ràng.
                    Button(action: { viewModel.clearCompletedAndFailedTasks() }) {
                        Label("Dọn dẹp hoàn tất/lỗi", systemImage: "trash.slash")
                    }
                    .help("Xóa các tác vụ đã hoàn tất hoặc bị lỗi")
                    .disabled(!viewModel.hasCompletedOrFailed)

                    Button(action: { showDeleteSelectedConfirm = true }) {
                        Label("Xóa mục đã chọn", systemImage: "trash")
                    }
                    .help("Xóa tác vụ đang chọn")
                    .disabled(viewModel.selectedTaskId == nil)
                }
            }
            .alert("Xóa tác vụ đang chọn?", isPresented: $showDeleteSelectedConfirm) {
                Button("Hủy", role: .cancel) {}
                Button("Xóa", role: .destructive) {
                    if let id = viewModel.selectedTaskId {
                        viewModel.deleteTask(id)
                    }
                }
            } message: {
                Text("Tác vụ đã chọn sẽ bị xóa khỏi danh sách. File đã tải xong vẫn giữ nguyên trên đĩa.")
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
        .sheet(item: $viewModel.pendingConfirmationTask, onDismiss: {
            // ESC dismiss không gọi onCancel → dọn task needsConfirmation mồ côi (C-F8).
            if let id = presentedConfirmationId {
                presentedConfirmationId = nil
                viewModel.handleConfirmationDismiss(taskId: id)
            }
        }) { task in
            DownloadConfirmationDialog(
                task: task,
                onStart: { filename, folder, segs, probedSize in
                    viewModel.confirmAndStartTask(taskId: task.id, filename: filename, destinationFolder: folder, segments: segs, totalBytes: probedSize)
                },
                onCancel: {
                    viewModel.cancelPendingConfirmation(task.id)
                }
            )
            .onAppear {
                presentedConfirmationId = task.id
            }
        }
    }
}
