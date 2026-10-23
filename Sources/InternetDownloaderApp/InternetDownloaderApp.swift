import SwiftUI
import AppKit
import DownloaderCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func terminateApplication() {
        guard !isTerminating else { return }
        isTerminating = true
        DownloadManager.shared.shutdown()
        NSApplication.shared.terminate(nil)
    }

    /// Đóng window khi còn downloading/pending → hỏi, không terminate ngay (C-F4).
    @objc private func handleWindowWillClose(_ notification: Notification) {
        guard !isTerminating, let window = notification.object as? NSWindow else { return }
        let mainWindowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if window.styleMask.contains(mainWindowStyle) && window.sheetParent == nil && !window.isSheet && !(window is NSPanel) {
            for sheet in window.sheets {
                window.endSheet(sheet)
            }
            let hasActive = DownloadManager.shared.getAllTasks().contains {
                $0.status == .downloading || $0.status == .pending
            }
            if hasActive {
                let alert = NSAlert()
                alert.messageText = "Vẫn còn tác vụ đang tải"
                alert.informativeText = "Đóng cửa sổ sẽ giữ ứng dụng chạy nền (menu bar) để tiếp tục tải. Chọn “Thoát ngay” để dừng mọi lượt tải."
                alert.addButton(withTitle: "Giữ chạy nền")
                alert.addButton(withTitle: "Thoát ngay")
                alert.alertStyle = .warning
                let response = alert.runModal()
                guard response == .alertSecondButtonReturn else { return }
            }
            terminateApplication()
        }
    }

    /// Giữ app sống (menu bar + tải nền) sau khi đóng window; thoát tường minh
    /// qua nút Thoát / alert xác nhận (C-F4).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isTerminating else { return }
        isTerminating = true
        DownloadManager.shared.shutdown()
    }
}

@main
struct InternetDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

                // Đọc progress/speed đã throttle 3Hz từ ViewModel (C-F15).
                if viewModel.cachedDownloadingCount > 0 {
                    Text("Đang tải: \(viewModel.cachedDownloadingCount) tác vụ · \(Int((viewModel.cachedOverallProgress * 100).rounded()))%")
                        .font(.caption)
                    Text("Tốc độ: \(FileTypeHelper.formatSpeed(viewModel.cachedAggregateSpeed))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Đang tải: 0 tác vụ")
                        .font(.caption)
                }

                Divider()

                Button("Thêm liên kết mới...") {
                    viewModel.showNewDownloadSheet = true
                    NSApp.activate(ignoringOtherApps: true)
                }

                Divider()

                Button("Mở cửa sổ chính") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !$0.isSheet && !($0 is NSPanel) }) ?? NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                }

                Button("Thoát") {
                    appDelegate.terminateApplication()
                }
            }
        }
    }
}
