import SwiftUI
import DownloaderCore

/// Equatable theo nội dung hiển thị (bỏ qua closure) để List bỏ qua row không đổi (C-F2).
public struct TaskRowView: View, Equatable {
    public let task: DownloadTask
    public let isSelected: Bool
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onDelete: () -> Void
    public let onOpen: () -> Void
    public let onReveal: () -> Void
    public let onRefreshAddress: (() -> Void)?
    public let onRetryAudio: (() -> Void)?

    public init(
        task: DownloadTask,
        isSelected: Bool,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onRefreshAddress: (() -> Void)? = nil,
        onRetryAudio: (() -> Void)? = nil
    ) {
        self.task = task
        self.isSelected = isSelected
        self.onPause = onPause
        self.onResume = onResume
        self.onDelete = onDelete
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onRefreshAddress = onRefreshAddress
        self.onRetryAudio = onRetryAudio
    }

    public static func == (lhs: TaskRowView, rhs: TaskRowView) -> Bool {
        lhs.task.id == rhs.task.id
            && lhs.task.filename == rhs.task.filename
            && lhs.task.status == rhs.task.status
            && lhs.task.downloadedBytes == rhs.task.downloadedBytes
            && lhs.task.totalBytes == rhs.task.totalBytes
            && lhs.task.speed == rhs.task.speed
            && lhs.task.segmentsCount == rhs.task.segmentsCount
            && lhs.task.downloadedSegmentsCount == rhs.task.downloadedSegmentsCount
            && lhs.task.errorMessage == rhs.task.errorMessage
            && lhs.task.audioState == rhs.task.audioState
            && lhs.task.browserInfo?.phase == rhs.task.browserInfo?.phase
            && lhs.task.browserInfo?.verification == rhs.task.browserInfo?.verification
            && lhs.isSelected == rhs.isSelected
    }

    public var body: some View {
        HStack(spacing: 12) {
            // File Icon
            Image(systemName: FileTypeHelper.iconName(for: task.filename))
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
                    .accessibilityLabel("Tiến độ tải \(task.filename)")
                    .accessibilityValue("\(Int((task.progress * 100).rounded())) phần trăm")

                // Sub-info: sizes, speed, ETA
                HStack(spacing: 8) {
                    Text(sizeAndProgressText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if task.status == .downloading && task.speed > 0 {
                        Text("• " + FileTypeHelper.formatSpeed(task.speed))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                    }

                    if let info = task.browserInfo {
                        Text("\(info.phaseLabel) · \(info.verification)").font(.caption2).foregroundColor(.secondary)
                    }

                    if let audio = task.audioState, audio == .missingInSource || audio == .unchecked {
                        Text("• " + audio.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                    } else if let audio = task.audioState, audio == .repaired {
                        Text("• " + audio.label)
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }

                    if let err = task.errorMessage {
                        Text("• " + err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }

                    Spacer()

                    // Quick Action Buttons (C-F11: hit-target tối thiểu 28pt)
                    HStack(spacing: 6) {
                        if task.status == .downloading || task.status == .pending {
                            Button(action: onPause) {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 10))
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(task.browserInfo == nil ? "Tạm dừng" : "Hủy phiên tải trình duyệt")
                            .accessibilityLabel(task.browserInfo == nil ? "Tạm dừng \(task.filename)" : "Hủy phiên tải trình duyệt \(task.filename)")
                        } else if task.status == .paused || task.status == .failed {
                            Button(action: onResume) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Tiếp tục tải")
                            .accessibilityLabel("Tiếp tục tải \(task.filename)")
                        }

                        if task.status == .completed {
                            Button(action: onOpen) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11))
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Mở file")
                            .accessibilityLabel("Mở file \(task.filename)")

                            Button(action: onReveal) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Hiển thị trong Finder")
                            .accessibilityLabel("Hiển thị \(task.filename) trong Finder")
                        }

                        if let onRetryAudio, task.status == .failed || task.audioState == .missingInSource {
                            Button(action: onRetryAudio) {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Tải lại bằng yt-dlp để lấy tiếng")
                            .accessibilityLabel("Tải lại \(task.filename) bằng yt-dlp để lấy tiếng")
                        }

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(minWidth: 28, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Xóa nhiệm vụ")
                        .accessibilityLabel("Xóa nhiệm vụ \(task.filename)")
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .contextMenu {
            if task.status == .downloading || task.status == .pending {
                Button(action: onPause) {
                    Label("Tạm dừng", systemImage: "pause.fill")
                }
            } else if task.status == .paused || task.status == .failed {
                Button(action: onResume) {
                    Label("Tiếp tục tải", systemImage: "play.fill")
                }
            }

            if let onRetryAudio, task.status == .failed || task.audioState == .missingInSource {
                Button(action: onRetryAudio) {
                    Label("Tải lại bằng yt-dlp để lấy tiếng", systemImage: "waveform.badge.magnifyingglass")
                }
            }

            if let onRefresh = onRefreshAddress, task.status != .completed {
                Button(action: onRefresh) {
                    Label("Cập nhật địa chỉ tải...", systemImage: "arrow.clockwise.circle")
                }
            }

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.url.absoluteString, forType: .string)
            }) {
                Label("Sao chép liên kết", systemImage: "doc.on.doc")
            }

            if task.status == .completed {
                Button(action: onOpen) {
                    Label("Mở file", systemImage: "arrow.up.forward.app")
                }
                Button(action: onReveal) {
                    Label("Hiển thị trong Finder", systemImage: "folder")
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Xóa tác vụ", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: TaskStatus) -> some View {
        switch status {
        case .downloading:
            pill("Đang tải", color: .blue)
        case .completed:
            pill("Hoàn tất", color: .green)
        case .paused:
            pill("Tạm dừng", color: .orange)
        case .failed:
            pill("Lỗi", color: .red)
        case .assembling:
            pill("Đang ghép file", color: .purple)
        case .needsConfirmation:
            // Pill thống nhất với các trạng thái khác (C-F16).
            pill("Cần xác nhận file trong Chrome", color: .orange)
        case .pending:
            pill("Chờ tải", color: .secondary)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
            .accessibilityLabel("Trạng thái: \(text)")
    }

    private var sizeAndProgressText: String {
        if task.status == .completed {
            return FileTypeHelper.formatBytes(task.totalBytes > 0 ? task.totalBytes : task.downloadedBytes)
        }
        if task.segmentsCount > 0 && task.downloadedSegmentsCount > 0 && task.status == .downloading {
            let downloadedStr = FileTypeHelper.formatBytes(task.downloadedBytes)
            let totalStr = task.totalBytes > 0 ? " / ~" + FileTypeHelper.formatBytes(task.totalBytes) : ""
            return "\(downloadedStr)\(totalStr) (\(task.downloadedSegmentsCount)/\(task.segmentsCount) phân đoạn)"
        }
        return FileTypeHelper.formatBytes(task.downloadedBytes) + (task.totalBytes > 0 ? " / " + FileTypeHelper.formatBytes(task.totalBytes) : "")
    }
}
