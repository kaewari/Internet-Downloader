import SwiftUI
import DownloaderCore

/// Equatable theo nội dung hiển thị để SwiftUI bỏ qua lần render không đổi (C-F2).
/// `segments` đã được ViewModel throttle 3Hz trước khi truyền xuống đây (C-F1).
public struct SegmentVisualizerView: View, Equatable {
    public let segments: [DownloadSegment]
    public let totalBytes: Int64

    public init(segments: [DownloadSegment], totalBytes: Int64) {
        self.segments = segments
        self.totalBytes = totalBytes
    }

    public static func == (lhs: SegmentVisualizerView, rhs: SegmentVisualizerView) -> Bool {
        lhs.totalBytes == rhs.totalBytes
            && lhs.segments.count == rhs.segments.count
            && zip(lhs.segments, rhs.segments).allSatisfy {
                $0.id == $1.id && $0.progress == $1.progress && $0.status == $1.status
            }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phân đoạn tải song song (IDM Segment Visualizer)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Text(segments.isEmpty ? "Đơn luồng" : "\(segments.count) kết nối")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            if segments.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 16)
                    .overlay(
                        Text("Đang kết nối luồng tải...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    )
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            SegmentBar(segment: segment, width: segmentWidth(for: segment, in: geometry.size.width))
                        }
                    }
                    // Gom toàn bộ bar thành 1 layer GPU thay vì N view riêng (C-F2).
                    .drawingGroup()
                }
                .frame(height: 18)

                // Segment labels grid
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(segments) { segment in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(statusColor(segment.status))
                                    .frame(width: 6, height: 6)
                                Text("#\(segment.index + 1): \(Int(segment.progress * 100))%")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .accessibilityLabel("Trực quan phân đoạn tải")
        .accessibilityValue(segments.isEmpty
            ? "Đơn luồng"
            : "\(segments.count) kết nối, \(completedCount)/\(segments.count) xong")
    }

    private var completedCount: Int {
        segments.filter { $0.status == .completed }.count
    }

    private func segmentWidth(for segment: DownloadSegment, in totalWidth: CGFloat) -> CGFloat {
        guard !segments.isEmpty else { return totalWidth }
        let spacing = CGFloat(max(0, segments.count - 1) * 2)
        let availableWidth = max(0, totalWidth - spacing)
        let totalExpected = segments.reduce(Int64(0)) { $0 + $1.expectedBytes }

        // If segments collectively span the whole file (HTTP range partitioning)
        if totalBytes > 0 && totalExpected > 0 && abs(Double(totalExpected - totalBytes)) <= Double(totalBytes) * 0.15 {
            let ratio = CGFloat(segment.expectedBytes) / CGFloat(totalBytes)
            return max(4, availableWidth * ratio)
        }

        // Otherwise (HLS worker slots or equal distribution), divide width equally among connections
        return max(4, availableWidth / CGFloat(segments.count))
    }

    private func statusColor(_ status: SegmentStatus) -> Color {
        switch status {
        case .completed: return .green
        case .downloading: return .blue
        case .paused: return .orange
        case .pending: return .gray.opacity(0.5)
        case .failed: return .red
        }
    }
}

/// Cache LinearGradient static theo status — không tạo mới mỗi tick (C-F2).
private struct SegmentBar: View, Equatable {
    let segment: DownloadSegment
    let width: CGFloat

    private static let completedGradient = LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
    private static let downloadingGradient = LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
    private static let pausedGradient = LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
    private static let failedGradient = LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
    private static let idleGradient = LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing)

    static func == (lhs: SegmentBar, rhs: SegmentBar) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.segment.progress == rhs.segment.progress
            && lhs.segment.status == rhs.segment.status
            && lhs.width == rhs.width
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.2))

            RoundedRectangle(cornerRadius: 2)
                .fill(barGradient)
                .frame(width: max(segment.status == .downloading ? 2 : 0, width * CGFloat(segment.progress)))
        }
        .frame(width: width, height: 16)
    }

    private var barGradient: LinearGradient {
        switch segment.status {
        case .completed: return Self.completedGradient
        case .downloading: return Self.downloadingGradient
        case .paused: return Self.pausedGradient
        case .failed: return Self.failedGradient
        case .pending: return Self.idleGradient
        }
    }
}
