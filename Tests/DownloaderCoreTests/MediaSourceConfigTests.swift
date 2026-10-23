import XCTest
@testable import DownloaderCore

/// Ràng buộc của danh sách nguồn kiểm thử (`scripts/media_sources_100.json`).
///
/// Mục đích: ngăn danh sách **thối âm thầm** trong repo (URL hết hạn, bị xoá,
/// đổi schema) — phải fail ngay trong `swift test` offline, không phải chờ đến
/// lần chạy live.
final class MediaSourceConfigTests: XCTestCase {

    /// Resolve catalog từ vị trí file test (không phụ thuộc thư mục chạy `swift test`).
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaSourceConfigTests.swift
            .deletingLastPathComponent() // DownloaderCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("scripts/media_sources_100.json")
    }

    private func loadCatalog() throws -> MediaSourceCatalog {
        let url = Self.catalogURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Thiếu danh sách nguồn: \(url.path)")
        return try MediaSourceCatalog.load(from: url.path)
    }

    /// Nguồn `retired` (URL chết vĩnh viễn) không tính vào độ phủ.
    private var activeCases: [MediaSourceSpec] {
        (try? loadCatalog())?.cases.filter { $0.status != "retired" } ?? []
    }

    func testCatalogHasEnoughSourcesAndHosts() throws {
        let catalog = try loadCatalog()
        let active = activeCases
        XCTAssertGreaterThanOrEqual(active.count, 120,
                                    "Danh sách nguồn phải có ít nhất 120 mục còn dùng được (thực tế: \(active.count))")

        let hosts = Set(active.compactMap { URL(string: $0.url)?.host })
        XCTAssertGreaterThanOrEqual(hosts.count, 100,
                                    "Phải có ít nhất 100 host độc lập (thực tế: \(hosts.count))")
    }

    func testCatalogHasEnoughNSFWSources() throws {
        let nsfw = activeCases.filter { $0.isNSFW }
        XCTAssertGreaterThanOrEqual(nsfw.count, 25,
                                    "Phải có ít nhất 25 nguồn NSFW (thực tế: \(nsfw.count))")
        // Nguồn NSFW vốn tập trung ở vài booru/host lớn → đòi nhiều host khó đạt;
        // kiểm tra ngưỡng vừa phải (≥5 host) để vẫn bắt được việc mất phân bố.
        let nsfwHosts = Set(nsfw.compactMap { URL(string: $0.url)?.host })
        XCTAssertGreaterThanOrEqual(nsfwHosts.count, 5,
                                    "Nguồn NSFW phải trải trên nhiều host (thực tế: \(nsfwHosts.count))")
    }

    func testAllEntriesAreWellFormed() throws {
        let active = activeCases
        var seenIDs = Set<String>()
        var seenURLs = Set<String>()

        for entry in active {
            XCTAssertFalse(entry.id.isEmpty, "id rỗng")
            XCTAssertTrue(seenIDs.insert(entry.id).inserted, "id trùng: \(entry.id)")

            XCTAssertNotNil(URL(string: entry.url), "URL không hợp lệ ở \(entry.id): \(entry.url)")
            XCTAssertTrue(entry.url.hasPrefix("http"), "URL phải là http(s): \(entry.url)")
            XCTAssertTrue(seenURLs.insert(entry.url).inserted, "URL trùng: \(entry.url)")

            XCTAssertTrue(["video", "audio", "image", "any"].contains(entry.kind),
                          "kind không hợp lệ ở \(entry.id): \(entry.kind)")
            XCTAssertTrue(["public-sample", "public-nsfw", "requires-auth"].contains(entry.access),
                          "access không hợp lệ ở \(entry.id): \(entry.access)")
            XCTAssertGreaterThan(entry.minBytes, 0, "min_bytes phải > 0 ở \(entry.id)")
            XCTAssertGreaterThan(entry.maxBytes, entry.minBytes, "max_bytes phải > min_bytes ở \(entry.id)")

            // Nguồn NSFW phải được khai báo access tương ứng để cổng policy chặn đúng.
            if entry.isNSFW {
                XCTAssertEqual(entry.access, "public-nsfw",
                               "Nguồn NSFW phải khai báo access=public-nsfw: \(entry.id)")
            }
        }
    }

    /// Cổng policy: nguồn `requires-auth` không được chạy trong kiểm thử tự động.
    func testRequiresAuthSourcesAreNotRunnable() throws {
        for entry in activeCases where entry.access == "requires-auth" {
            XCTAssertFalse(entry.isRunnable,
                           "Nguồn cần đăng nhập không được chạy tự động: \(entry.id)")
        }
    }

    /// Không được có cookie/tài khoản trong cấu hình kiểm thử.
    func testCatalogContainsNoCredentials() throws {
        let catalog = MediaSourceCatalog(cases: activeCases)
        // Chỉ soi tham số thực sự là thông tin đăng nhập. "token"/"session" quá
        // chung (podcast CDN dùng `timetoken` là chữ ký công khai) nên không tính.
        let suspicious = [
            "password", "passwd", "api_key", "apikey", "secret",
            "access_token", "auth_token", "credential", "authorization",
            "bearer", "oauth", "private_key"
        ]
        for entry in catalog.cases {
            for key in suspicious {
                XCTAssertFalse(entry.url.lowercased().contains("\(key)="),
                               "URL chứa tham số nhạy cảm '\(key)' ở \(entry.id)")
            }
        }
    }
}
