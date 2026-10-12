import Foundation

final class HTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects: [Int: Int] = [:]
    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    static func safeRequest(_ request: URLRequest, previous: URL?, count: Int) -> URLRequest? {
        guard count <= 10, let url = request.url, URLNormalizer.normalize(url.absoluteString) != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var result = request; result.httpShouldHandleCookies = false
        if origin(previous) != origin(url) {
            for key in result.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys {
                if !["accept", "range", "user-agent", "accept-encoding"].contains(key.lowercased()) { result.setValue(nil, forHTTPHeaderField: key) }
            }
        }
        return result
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let count = lock.withLock { redirects[task.taskIdentifier, default: 0] += 1; return redirects[task.taskIdentifier]! }
        completionHandler(Self.safeRequest(request, previous: response.url, count: count))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { _ = lock.withLock { redirects.removeValue(forKey: task.taskIdentifier) } }
}
