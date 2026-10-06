import SwiftUI
import DownloaderCore

public struct MainWindow: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

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
                                onReveal: { viewModel.revealInFinder(task) }
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

                    Button(action: { pauseAll() }) {
                        Label("Tạm dừng tất cả", systemImage: "pause.circle")
                    }
                    .help("Tạm dừng tất cả tác vụ đang tải")

                    Button(action: { resumeAll() }) {
                        Label("Tiếp tục tất cả", systemImage: "play.circle")
                    }
                    .help("Tiếp tục tất cả tác vụ")
                }
            }
        }
        .sheet(isPresented: $viewModel.showNewDownloadSheet) {
            NewDownloadDialog(isPresented: $viewModel.showNewDownloadSheet) { url, filename, folder, segs in
                viewModel.addNewDownload(url: url, filename: filename, destinationFolder: folder, segments: segs)
            }
        }
    }

    private func count(for category: DownloadCategory) -> Int {
        switch category {
        case .all: return viewModel.tasks.count
        case .downloading: return viewModel.tasks.filter { $0.status == .downloading || $0.status == .pending }.count
        case .completed: return viewModel.tasks.filter { $0.status == .completed }.count
        case .paused: return viewModel.tasks.filter { $0.status == .paused }.count
        }
    }

    private func pauseAll() {
        for t in viewModel.tasks where t.status == .downloading {
            viewModel.pauseTask(t.id)
        }
    }

    private func resumeAll() {
        for t in viewModel.tasks where t.status == .paused {
            viewModel.resumeTask(t.id)
        }
    }
}
