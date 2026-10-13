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

    @objc private func handleWindowWillClose(_ notification: Notification) {
        guard !isTerminating, let window = notification.object as? NSWindow else { return }
        let mainWindowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if window.styleMask.contains(mainWindowStyle) && window.sheetParent == nil && !window.isSheet && !(window is NSPanel) {
            for sheet in window.sheets {
                window.endSheet(sheet)
            }
            terminateApplication()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
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
