import SwiftUI
import DownloaderCore

@main
struct InternetDownloaderApp: App {
    @StateObject private var viewModel = DownloadManagerViewModel()

    var body: some Scene {
        WindowGroup {
            MainWindow(viewModel: viewModel)
                .frame(minWidth: 780, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        MenuBarExtra("Internet Downloader", systemImage: "arrow.down.circle.fill") {
            VStack(alignment: .leading) {
                Text("Internet Downloader")
                    .font(.headline)

                let downloadingCount = viewModel.tasks.filter { $0.status == .downloading }.count
                Text("Đang tải: \(downloadingCount) tác vụ")
                    .font(.caption)

                Divider()

                Button("Thêm liên kết mới...") {
                    viewModel.showNewDownloadSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                }

                Divider()

                Button("Mở cửa sổ chính") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                Button("Thoát") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
