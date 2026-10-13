import Foundation
import SQLite3

public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.internetdownloader.sqlite.queue")

    public init(path: String) throws {
        var dbPointer: OpaquePointer?
        if path != ":memory:" {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if sqlite3_open(path, &dbPointer) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(dbPointer))
            throw NSError(domain: "SQLiteStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite database: \(errorMessage)"])
        }
        self.db = dbPointer
        try createTables()
        try migrateSchema()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func createTables() throws {
        let sql = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            filename TEXT NOT NULL,
            destination_folder TEXT NOT NULL,
            total_bytes INTEGER NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            status TEXT NOT NULL,
            speed REAL NOT NULL,
            etag TEXT,
            last_modified TEXT,
            accept_ranges INTEGER NOT NULL,
            segments_count INTEGER NOT NULL,
            downloaded_segments_count INTEGER DEFAULT 0,
            error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            referrer TEXT,
            user_agent TEXT,
            cookies TEXT,
            browser_info TEXT,
            headers TEXT
        );

        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            segment_index INTEGER NOT NULL,
            start_byte INTEGER NOT NULL,
            end_byte INTEGER NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            status TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_segments_task_id ON segments(task_id);
        """

        try queue.sync {
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errMsg)
                throw NSError(domain: "SQLiteStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Table creation failed: \(msg)"])
            }
        }
    }

    private func migrateSchema() throws {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(tasks)", -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteStore", code: 12) }
            var foundBrowser = false
            var foundSegments = false
            var foundHeaders = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 1) {
                    let col = String(cString: text)
                    if col == "browser_info" { foundBrowser = true }
                    if col == "downloaded_segments_count" { foundSegments = true }
                    if col == "headers" { foundHeaders = true }
                }
            }
            sqlite3_finalize(stmt)
            if !foundBrowser && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN browser_info TEXT", nil, nil, nil) != SQLITE_OK {
                throw NSError(domain: "SQLiteStore", code: 13)
            }
            if !foundSegments && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN downloaded_segments_count INTEGER DEFAULT 0", nil, nil, nil) != SQLITE_OK {
                throw NSError(domain: "SQLiteStore", code: 14)
            }
            if !foundHeaders && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN headers TEXT", nil, nil, nil) != SQLITE_OK {
                throw NSError(domain: "SQLiteStore", code: 15)
            }
        }
    }

    public func saveTask(_ task: DownloadTask) throws {
        try queue.sync {
            let sql = """
            INSERT INTO tasks (
                id, url, filename, destination_folder, total_bytes, downloaded_bytes,
                status, speed, etag, last_modified, accept_ranges, segments_count,
                error_message, created_at, updated_at, referrer, user_agent, cookies, browser_info,
                downloaded_segments_count, headers
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                total_bytes=excluded.total_bytes,
                downloaded_bytes=excluded.downloaded_bytes,
                status=excluded.status,
                speed=excluded.speed,
                etag=excluded.etag,
                last_modified=excluded.last_modified,
                accept_ranges=excluded.accept_ranges,
                segments_count=excluded.segments_count,
                downloaded_segments_count=excluded.downloaded_segments_count,
                error_message=excluded.error_message,
                updated_at=excluded.updated_at,
                url=excluded.url, filename=excluded.filename, destination_folder=excluded.destination_folder,
                referrer=excluded.referrer, user_agent=excluded.user_agent, cookies=excluded.cookies,
                browser_info=excluded.browser_info, headers=excluded.headers;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            let idStr = task.id.uuidString
            sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (task.url.absoluteString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (task.filename as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (task.destinationFolder.path as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 5, task.totalBytes)
            sqlite3_bind_int64(stmt, 6, task.downloadedBytes)
            sqlite3_bind_text(stmt, 7, (task.status.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 8, task.speed)

            if let etag = task.etag {
                sqlite3_bind_text(stmt, 9, (etag as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            if let lastModified = task.lastModified {
                sqlite3_bind_text(stmt, 10, (lastModified as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 10)
            }

            sqlite3_bind_int(stmt, 11, task.acceptRanges ? 1 : 0)
            sqlite3_bind_int(stmt, 12, Int32(task.segmentsCount))

            if let err = task.errorMessage {
                sqlite3_bind_text(stmt, 13, (err as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 13)
            }

            sqlite3_bind_double(stmt, 14, task.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 15, task.updatedAt.timeIntervalSince1970)

            if let ref = task.referrer {
                sqlite3_bind_text(stmt, 16, (ref as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 16)
            }
            if let ua = task.userAgent {
                sqlite3_bind_text(stmt, 17, (ua as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 17)
            }
            if let c = task.cookies {
                sqlite3_bind_text(stmt, 18, (c as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 18)
            }

            if let info = task.browserInfo {
                let encoded = String(data: try JSONEncoder().encode(info), encoding: .utf8)!
                sqlite3_bind_text(stmt, 19, (encoded as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else { sqlite3_bind_null(stmt, 19) }
            sqlite3_bind_int(stmt, 20, Int32(task.downloadedSegmentsCount))

            if let headers = task.headers, let encoded = try? JSONEncoder().encode(headers), let str = String(data: encoded, encoding: .utf8) {
                sqlite3_bind_text(stmt, 21, (str as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else { sqlite3_bind_null(stmt, 21) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "SQLiteStore", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

    public func getAllTasks() throws -> [DownloadTask] {
        try queue.sync {
            let sql = "SELECT id, url, filename, destination_folder, total_bytes, downloaded_bytes, status, speed, etag, last_modified, accept_ranges, segments_count, error_message, created_at, updated_at, referrer, user_agent, cookies, browser_info, downloaded_segments_count, headers FROM tasks ORDER BY created_at DESC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 5, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            var tasks: [DownloadTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                      let id = UUID(uuidString: idStr),
                      let urlStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                      let url = URL(string: urlStr),
                      let filename = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                      let destPath = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                      let statusStr = sqlite3_column_text(stmt, 6).map({ String(cString: $0) }),
                      let status = TaskStatus(rawValue: statusStr) else {
                    continue
                }

                let totalBytes = sqlite3_column_int64(stmt, 4)
                let downloadedBytes = sqlite3_column_int64(stmt, 5)
                let speed = sqlite3_column_double(stmt, 7)
                let etag = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                let lastModified = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let acceptRanges = sqlite3_column_int(stmt, 10) == 1
                let segmentsCount = Int(sqlite3_column_int(stmt, 11))
                let errorMessage = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
                let referrer = sqlite3_column_text(stmt, 15).map { String(cString: $0) }
                let userAgent = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
                let cookies = sqlite3_column_text(stmt, 17).map { String(cString: $0) }
                let downloadedSegmentsCount = Int(sqlite3_column_int(stmt, 19))

                var task = DownloadTask(
                    id: id,
                    url: url,
                    filename: filename,
                    destinationFolder: URL(fileURLWithPath: destPath),
                    totalBytes: totalBytes,
                    downloadedBytes: downloadedBytes,
                    status: status,
                    speed: speed,
                    etag: etag,
                    lastModified: lastModified,
                    acceptRanges: acceptRanges,
                    segmentsCount: segmentsCount,
                    downloadedSegmentsCount: downloadedSegmentsCount,
                    errorMessage: errorMessage,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    referrer: referrer,
                    userAgent: userAgent,
                    cookies: cookies
                )
                if let text = sqlite3_column_text(stmt, 18) {
                    task.browserInfo = try JSONDecoder().decode(BrowserTaskInfo.self, from: Data(String(cString: text).utf8))
                }
                if let text = sqlite3_column_text(stmt, 20) {
                    task.headers = try? JSONDecoder().decode([String: String].self, from: Data(String(cString: text).utf8))
                }
                tasks.append(task)
            }
            return tasks
        }
    }

    public func getTask(id: UUID) throws -> DownloadTask? {
        try queue.sync {
            let sql = "SELECT id, url, filename, destination_folder, total_bytes, downloaded_bytes, status, speed, etag, last_modified, accept_ranges, segments_count, error_message, created_at, updated_at, referrer, user_agent, cookies, browser_info, downloaded_segments_count, headers FROM tasks WHERE id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 6, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            let idStr = id.uuidString
            sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            guard let urlStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let url = URL(string: urlStr),
                  let filename = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let destPath = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let statusStr = sqlite3_column_text(stmt, 6).map({ String(cString: $0) }),
                  let status = TaskStatus(rawValue: statusStr) else {
                return nil
            }

            let totalBytes = sqlite3_column_int64(stmt, 4)
            let downloadedBytes = sqlite3_column_int64(stmt, 5)
            let speed = sqlite3_column_double(stmt, 7)
            let etag = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let lastModified = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let acceptRanges = sqlite3_column_int(stmt, 10) == 1
            let segmentsCount = Int(sqlite3_column_int(stmt, 11))
            let errorMessage = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
            let referrer = sqlite3_column_text(stmt, 15).map { String(cString: $0) }
            let userAgent = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
            let cookies = sqlite3_column_text(stmt, 17).map { String(cString: $0) }
            let downloadedSegmentsCount = Int(sqlite3_column_int(stmt, 19))

            var task = DownloadTask(
                id: id,
                url: url,
                filename: filename,
                destinationFolder: URL(fileURLWithPath: destPath),
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                status: status,
                speed: speed,
                etag: etag,
                lastModified: lastModified,
                acceptRanges: acceptRanges,
                segmentsCount: segmentsCount,
                downloadedSegmentsCount: downloadedSegmentsCount,
                errorMessage: errorMessage,
                createdAt: createdAt,
                updatedAt: updatedAt,
                referrer: referrer,
                userAgent: userAgent,
                cookies: cookies
            )
            if let text = sqlite3_column_text(stmt, 18) {
                task.browserInfo = try JSONDecoder().decode(BrowserTaskInfo.self, from: Data(String(cString: text).utf8))
            }
            if let text = sqlite3_column_text(stmt, 20) {
                task.headers = try? JSONDecoder().decode([String: String].self, from: Data(String(cString: text).utf8))
            }
            return task
        }
    }

    public func deleteTask(id: UUID) throws {
        try queue.sync {
            let idStr = id.uuidString

            let deleteSegSql = "DELETE FROM segments WHERE task_id = ?;"
            var segStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSegSql, -1, &segStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(segStmt, 1, (idStr as NSString).utf8String, -1, nil)
                _ = sqlite3_step(segStmt)
                sqlite3_finalize(segStmt)
            }

            let sql = "DELETE FROM tasks WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 7, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "SQLiteStore", code: 8, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

    public func deleteFailedTasks() throws {
        try queue.sync {
            let deleteSegmentsSql = "DELETE FROM segments WHERE task_id IN (SELECT id FROM tasks WHERE status = 'failed');"
            var segStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSegmentsSql, -1, &segStmt, nil) == SQLITE_OK {
                _ = sqlite3_step(segStmt)
                sqlite3_finalize(segStmt)
            }

            let sql = "DELETE FROM tasks WHERE status = 'failed';"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 14, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "SQLiteStore", code: 15, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

    public func deleteCompletedAndFailedTasks() throws {
        try queue.sync {
            let deleteSegmentsSql = "DELETE FROM segments WHERE task_id IN (SELECT id FROM tasks WHERE status IN ('completed', 'failed'));"
            var segStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSegmentsSql, -1, &segStmt, nil) == SQLITE_OK {
                _ = sqlite3_step(segStmt)
                sqlite3_finalize(segStmt)
            }

            let sql = "DELETE FROM tasks WHERE status IN ('completed', 'failed');"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 16, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "SQLiteStore", code: 17, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

    public func saveSegments(_ segments: [DownloadSegment]) throws {
        try queue.sync {
            let sql = """
            INSERT INTO segments (id, task_id, segment_index, start_byte, end_byte, downloaded_bytes, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                downloaded_bytes=excluded.downloaded_bytes,
                status=excluded.status;
            """
            for segment in segments {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw NSError(domain: "SQLiteStore", code: 9, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
                }

                let idStr = segment.id.uuidString
                let taskIdStr = segment.taskId.uuidString
                sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (taskIdStr as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 3, Int32(segment.index))
                sqlite3_bind_int64(stmt, 4, segment.startByte)
                sqlite3_bind_int64(stmt, 5, segment.endByte)
                sqlite3_bind_int64(stmt, 6, segment.downloadedBytes)
                sqlite3_bind_text(stmt, 7, (segment.status.rawValue as NSString).utf8String, -1, nil)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    let err = String(cString: sqlite3_errmsg(db))
                    sqlite3_finalize(stmt)
                    throw NSError(domain: "SQLiteStore", code: 10, userInfo: [NSLocalizedDescriptionKey: err])
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    public func getSegments(for taskId: UUID) throws -> [DownloadSegment] {
        try queue.sync {
            let sql = "SELECT id, task_id, segment_index, start_byte, end_byte, downloaded_bytes, status FROM segments WHERE task_id = ? ORDER BY segment_index ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteStore", code: 11, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            defer { sqlite3_finalize(stmt) }

            let taskIdStr = taskId.uuidString
            sqlite3_bind_text(stmt, 1, (taskIdStr as NSString).utf8String, -1, nil)

            var segments: [DownloadSegment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                      let id = UUID(uuidString: idStr),
                      let tIdStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                      let tId = UUID(uuidString: tIdStr),
                      let statusStr = sqlite3_column_text(stmt, 6).map({ String(cString: $0) }),
                      let status = SegmentStatus(rawValue: statusStr) else {
                    continue
                }

                let index = Int(sqlite3_column_int(stmt, 2))
                let startByte = sqlite3_column_int64(stmt, 3)
                let endByte = sqlite3_column_int64(stmt, 4)
                let downloadedBytes = sqlite3_column_int64(stmt, 5)

                let segment = DownloadSegment(
                    id: id,
                    taskId: tId,
                    index: index,
                    startByte: startByte,
                    endByte: endByte,
                    downloadedBytes: downloadedBytes,
                    status: status
                )
                segments.append(segment)
            }
            return segments
        }
    }
}
