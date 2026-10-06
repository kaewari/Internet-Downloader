import SwiftUI
import DownloaderCore

public struct TaskRowView: View {
    public let task: DownloadTask
    public let isSelected: Bool
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onDelete: () -> Void
    public let onOpen: () -> Void
    public let onReveal: () -> Void

    public init(
        task: DownloadTask,
        isSelected: Bool,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) {
        self.task = task
        self.isSelected = isSelected
        self.onPause = onPause
        self.onResume = onResume
        self.onDelete = onDelete
        self.onOpen = onOpen
        self.onReveal = onReveal
    }

    public var body: some View {
        HStack(spacing: 12) {
            // File Icon
            Image(systemName: fileIconName(for: task.filename))
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 32)

            // Info Column
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    statusBadge(task.status)
                }

                // Progress Bar
                ProgressView(value: task.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 6)

                // Sub-info: sizes, speed, ETA
                HStack(spacing: 8) {
                    Text(formatBytes(task.downloadedBytes) + (task.totalBytes > 0 ? " / " + formatBytes(task.totalBytes) : ""))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if task.status == .downloading && task.speed > 0 {
                        Text("• " + formatSpeed(task.speed))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                    }

                    if let err = task.errorMessage {
                        Text("• " + err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Quick Action Buttons
                    HStack(spacing: 6) {
                        if task.status == .downloading {
                            Button(action: onPause) {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Tạm dừng")
                        } else if task.status == .paused || task.status == .failed {
                            Button(action: onResume) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Tiếp tục tải")
                        }

                        if task.status == .completed {
                            Button(action: onOpen) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Mở file")

                            Button(action: onReveal) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Hiển thị trong Finder")
                        }

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Xóa nhiệm vụ")
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
    }

    private func fileIconName(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "ts": return "film"
        case "mp3", "m4a", "flac", "wav", "aac": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "dmg", "pkg", "iso", "app": return "shippingbox"
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "webp", "gif": return "photo"
        default: return "doc"
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: TaskStatus) -> some View {
        switch status {
        case .downloading:
            Text("Đang tải")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(4)
        case .completed:
            Text("Hoàn tất")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)
        case .paused:
            Text("Tạm dừng")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(4)
        case .failed:
            Text("Lỗi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        case .assembling:
            Text("Đang ghép file")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(4)
        case .pending:
            Text("Chờ tải")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        let count = Int64(bytesPerSec)
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file) + "/s"
    }
}
