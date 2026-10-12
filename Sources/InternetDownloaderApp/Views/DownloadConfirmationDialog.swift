import SwiftUI
import AppKit
import DownloaderCore

public struct DownloadConfirmationDialog: View {
    public let task: DownloadTask
    public let onStart: (String, URL, Int, Int64?) -> Void
    public let onCancel: () -> Void

    @State private var filename: String
    @State private var destinationFolder: URL
    @State private var segmentsCount: Int
    @State private var totalBytes: Int64
    @State private var isProbingSize: Bool = false

    public init(
        task: DownloadTask,
        onStart: @escaping (String, URL, Int, Int64?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.onStart = onStart
        self.onCancel = onCancel
        var initFilename = task.filename
        if initFilename.isEmpty || initFilename == "download" || FileTypeDetector.isOpaqueIdentifier(initFilename) {
            if let extracted = FileTypeDetector.extractFilename(from: task.url) {
                initFilename = extracted
            }
        }
        self._filename = State(initialValue: initFilename)
        self._destinationFolder = State(initialValue: task.destinationFolder)
        self._segmentsCount = State(initialValue: task.segmentsCount > 0 ? task.segmentsCount : 8)
        self._totalBytes = State(initialValue: task.totalBytes)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: fileIconName(for: filename))
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bắt đầu tải tệp tin")
                        .font(.headline)
                    Text(task.url.host ?? task.url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Địa chỉ URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(task.url.absoluteString)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tên tệp:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Tên file", text: $filename)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Dung lượng media:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    if isProbingSize {
                        ProgressView()
                            .controlSize(.small)
                        Text("Đang kiểm tra dung lượng media...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if totalBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.accentColor)
                    } else {
                        Text("Không xác định (Đa phân đoạn / Stream)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Lưu vào thư mục:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text(destinationFolder.path)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(4)

                    Button("Chọn...") {
                        selectDestinationFolder()
                    }
                }
            }

            HStack {
                Text("Số luồng kết nối:")
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

            Divider()

            HStack {
                Button("Hủy") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Bắt đầu tải") {
                    let clean = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    onStart(clean.isEmpty ? task.filename : clean, destinationFolder, segmentsCount, totalBytes > 0 ? totalBytes : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            isProbingSize = true
            let currentExt = (filename as NSString).pathExtension
            let isOpaqueOrEmpty = filename.isEmpty || filename == "download" || FileTypeDetector.isOpaqueIdentifier(filename) || currentExt.isEmpty

            if let probe = try? await HTTPRangeDownloader.probeURL(
                url: task.url,
                customHeaders: task.headers,
                cookies: task.cookies,
                userAgent: task.userAgent
            ) {
                if probe.totalBytes > 0 {
                    self.totalBytes = probe.totalBytes
                }
                if let suggested = probe.suggestedFilename, !suggested.isEmpty {
                    let suggestedExt = (suggested as NSString).pathExtension
                    if isOpaqueOrEmpty || (currentExt.isEmpty && !suggestedExt.isEmpty) {
                        self.filename = suggested
                    }
                }
            } else if totalBytes <= 0 {
                let (probedSize, probedTitle) = await MediaURLResolver.probeMediaSizeAndTitle(
                    url: task.url,
                    userAgent: task.userAgent,
                    cookies: task.cookies
                )
                if probedSize > 0 {
                    self.totalBytes = probedSize
                }
                if let probedTitle = probedTitle, !probedTitle.isEmpty {
                    let clean = probedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let current = filename.lowercased()
                    if current.isEmpty || current.hasPrefix("download") || current.contains("manifest") || current.hasSuffix(".bin") || FileTypeDetector.isOpaqueIdentifier(current) {
                        let ext = task.url.pathExtension.isEmpty ? "mp4" : task.url.pathExtension
                        self.filename = "\(clean).\(ext)"
                    }
                }
            }
            isProbingSize = false
        }
    }

    private func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Chọn thư mục"
        panel.directoryURL = destinationFolder

        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.destinationFolder = selectedURL
        }
    }

    private func fileIconName(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "ts", "m3u8": return "film"
        case "mp3", "m4a", "flac", "wav", "aac": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "dmg", "pkg", "iso", "app": return "shippingbox"
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "webp", "gif": return "photo"
        default: return "arrow.down.doc"
        }
    }
}
