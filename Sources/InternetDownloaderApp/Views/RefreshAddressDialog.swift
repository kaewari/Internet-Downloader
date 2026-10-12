import SwiftUI
import AppKit
import DownloaderCore

public struct RefreshAddressDialog: View {
    @Binding public var isPresented: Bool
    public let task: DownloadTask
    public let onUpdate: (URL, String?) -> Void

    @State private var newURLString: String = ""
    @State private var newReferrer: String = ""
    @State private var errorMessage: String?

    public init(
        isPresented: Binding<Bool>,
        task: DownloadTask,
        onUpdate: @escaping (URL, String?) -> Void
    ) {
        self._isPresented = isPresented
        self.task = task
        self.onUpdate = onUpdate
        self._newReferrer = State(initialValue: task.referrer ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cập nhật địa chỉ tải")
                        .font(.headline)
                    Text("Thay thế liên kết đã hết hạn để tiếp tục tải tệp này.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tệp:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(task.filename)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

            if let err = task.errorMessage {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lỗi hiện tại:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Địa chỉ URL mới:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Dán từ Clipboard") {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           clip.hasPrefix("http://") || clip.hasPrefix("https://") {
                            newURLString = clip
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                TextField("https://...", text: $newURLString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Referrer mới (tùy chọn):")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://...", text: $newReferrer)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Hủy") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Cập nhật và tiếp tục tải") {
                    validateAndUpdate()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.hasPrefix("http://") || clip.hasPrefix("https://"),
               clip != task.url.absoluteString {
                newURLString = clip
            }
        }
    }

    private func validateAndUpdate() {
        let trimmed = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            errorMessage = "Vui lòng nhập địa chỉ HTTP/HTTPS hợp lệ."
            return
        }
        let ref = newReferrer.trimmingCharacters(in: .whitespacesAndNewlines)
        onUpdate(url, ref.isEmpty ? nil : ref)
        isPresented = false
    }
}
