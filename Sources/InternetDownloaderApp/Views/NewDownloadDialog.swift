import SwiftUI
import AppKit
import DownloaderCore

public struct NewDownloadDialog: View {
    @Binding public var isPresented: Bool
    public let onAdd: (URL, String, URL, Int) -> Void

    @State private var urlString: String = ""
    @State private var filename: String = ""
    @State private var destinationFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @State private var segmentsCount: Int = 8
    @State private var errorMessage: String?

    public init(
        isPresented: Binding<Bool>,
        initialURL: String? = nil,
        onAdd: @escaping (URL, String, URL, Int) -> Void
    ) {
        self._isPresented = isPresented
        self._urlString = State(initialValue: initialURL ?? "")
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Thêm liên kết tải mới")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Địa chỉ URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://example.com/file.zip", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: urlString) { newValue in
                        autoPopulateFilename(from: newValue)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tên file:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("file.zip", text: $filename)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Thư mục lưu:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text(destinationFolder.path)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)

                    Button("Chọn...") {
                        selectDestinationFolder()
                    }
                }
            }

            HStack {
                Text("Số luồng kết nối song song:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $segmentsCount) {
                    Text("1 (Đơn luồng)").tag(1)
                    Text("4 luồng").tag(4)
                    Text("8 luồng (Khuyên dùng)").tag(8)
                    Text("16 luồng (Siêu tốc)").tag(16)
                }
                .frame(width: 180)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            HStack {
                Button("Dán từ Clipboard") {
                    pasteFromClipboard()
                }
                Spacer()
                Button("Hủy") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Bắt đầu tải") {
                    startDownload()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if urlString.isEmpty {
                pasteFromClipboard()
            } else {
                autoPopulateFilename(from: urlString)
            }
        }
    }

    private func pasteFromClipboard() {
        if let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clipboard.hasPrefix("http://") || clipboard.hasPrefix("https://") {
            self.urlString = clipboard
            autoPopulateFilename(from: clipboard)
        }
    }

    private func autoPopulateFilename(from urlStr: String) {
        if let url = URL(string: urlStr) {
            if let extracted = FileTypeDetector.extractFilename(from: url) {
                self.filename = extracted
            } else if !url.lastPathComponent.isEmpty {
                self.filename = url.lastPathComponent
            }
        }
    }

    private func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Chọn thư mục"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.destinationFolder = selectedURL
        }
    }

    private func startDownload() {
        guard let url = URLNormalizer.normalize(urlString) else {
            errorMessage = "Vui lòng nhập URL hợp lệ (HTTP, HTTPS hoặc Data URL)."
            return
        }

        onAdd(url, filename, destinationFolder, segmentsCount)
        isPresented = false
    }
}
