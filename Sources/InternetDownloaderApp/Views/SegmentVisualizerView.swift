import SwiftUI
import DownloaderCore

public struct SegmentVisualizerView: View {
    public let segments: [DownloadSegment]
    public let totalBytes: Int64

    public init(segments: [DownloadSegment], totalBytes: Int64) {
        self.segments = segments
        self.totalBytes = totalBytes
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

private struct SegmentBar: View {
    let segment: DownloadSegment
    let width: CGFloat

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
        case .completed:
            return LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
        case .downloading:
            return LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
        case .paused:
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        default:
            return LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing)
        }
    }
}
