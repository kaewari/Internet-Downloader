import Foundation

enum RetryPolicy {
    /// Tổng số lần thử (1 lần đầu + 3 lần retry) — dùng hết backoff [1,2,4] (A-F10).
    static let maxAttempts = 4
    static let backoffDelays: [TimeInterval] = [1.0, 2.0, 4.0]

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // 412/416 sau If-Range: resource đã đổi — retry Range cũ vô nghĩa,
        // vòng re-probe của `download` xử lý riêng (A-F11).
        if error is HTTPResourceChangedError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet,
                  .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
                  .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let hlsError = error as? HLSDownloadError {
            return hlsError.isRetryable
        }
        if let nsError = error as NSError?, nsError.domain == "HTTPRangeDownloader" || nsError.domain == "HLSDownloader" {
            // 5xx server errors, 429 rate limiting và 408 timeout đều retry được;
            // 4xx còn lại thì không. Dùng chung cho Range + HLS (A-F10).
            return (500...599).contains(nsError.code) || nsError.code == 429 || nsError.code == 408
        }
        return false
    }

    /// Có nên retry sau lần thử `failedAttempt` (0-based) fail không.
    /// Gộp isRetryable + giới hạn số lần — caller không tự `-1` (A-F10).
    static func shouldRetry(failedAttempt attempt: Int, error: Error) -> Bool {
        guard isRetryable(error) else { return false }
        return attempt + 1 < maxAttempts
    }

    static func retryDelay(attempt: Int, retryAfterHeader: String?) -> TimeInterval? {
        guard attempt + 1 < maxAttempts else { return nil }
        if let header = retryAfterHeader, !header.isEmpty,
           let retryAfter = parseRetryAfter(header) {
            return retryAfter
        }
        // Index an toàn khi backoff ngắn hơn số lần retry (A-F10).
        return backoffDelays[min(attempt, backoffDelays.count - 1)]
    }

    /// Parse Retry-After: số giây hoặc HTTP-date (RFC 1123/850/asctime).
    /// Trả `nil` khi header vô lý (số âm/quá 300s, date quá khứ/không parse
    /// được) để caller fallback sang backoff (A-F10).
    private static func parseRetryAfter(_ header: String) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds >= 0 {
            guard seconds < 300 else { return nil }
            return seconds
        }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz", // RFC 1123: Sun, 06 Nov 1994 08:49:37 GMT
            "EEEE, dd-MMM-yy HH:mm:ss zzz", // RFC 850: Sunday, 06-Nov-94 08:49:37 GMT
            "EEE MMM d HH:mm:ss yyyy" // asctime: Sun Nov  6 08:49:37 1994
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let delta = date.timeIntervalSinceNow
                guard delta > 0 else { return nil }
                return min(delta, 300)
            }
        }
        return nil
    }
}
