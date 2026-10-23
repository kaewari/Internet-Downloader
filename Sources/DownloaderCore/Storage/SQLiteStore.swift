import Foundation
import SQLite3

/// SQLITE_TRANSIENT (-1): instructs SQLite to copy bound text immediately (B1).
/// Every `sqlite3_bind_text` in this file MUST use it: the source pointer comes
/// from `(… as NSString).utf8String`, a temporary object that may be freed right
/// after the bind call. Passing nil (= SQLITE_STATIC) would leave SQLite with a
/// dangling pointer (use-after-free).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Unique error codes for SQLiteStore (B9).
/// Values 1–17 keep their historical numeric meaning (NSError domain
/// "SQLiteStore" compat). Codes 14/15/16 were previously duplicated between
/// schema migration and the batch-delete helpers; the batch-delete cases were
/// renumbered to 18/19/20 to make every code unique.
public enum StoreError: Int, Error, Sendable {
    case openFailed = 1
    case tableCreationFailed = 2
    case prepareSaveTask = 3
    case stepSaveTask = 4
    case prepareGetAllTasks = 5
    case prepareGetTask = 6
    case prepareDeleteTask = 7
    case stepDeleteTask = 8
    case prepareSaveSegments = 9
    case stepSaveSegments = 10
    case prepareGetSegments = 11
    case prepareTableInfo = 12
    case migrateBrowserInfo = 13
    case migrateSegmentsCount = 14
    case migrateHeaders = 15
    case migrateAudioState = 16
    case stepDeleteCompletedAndFailedTasks = 17
    case prepareDeleteFailedTasks = 18 // was 14 (collided with migrateSegmentsCount)
    case stepDeleteFailedTasks = 19 // was 15 (collided with migrateHeaders)
    case prepareDeleteCompletedAndFailedTasks = 20 // was 16 (collided with migrateAudioState)
    case beginTransactionFailed = 22
    case commitTransactionFailed = 23

    func nsError(_ message: String = "") -> NSError {
        NSError(domain: "SQLiteStore", code: rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

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
            let errorMessage = dbPointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.openFailed.nsError("Failed to open SQLite database: \(errorMessage)")
        }
        self.db = dbPointer
        // B5: avoid SQLITE_BUSY failures under concurrent readers/writers.
        // Best-effort: a failure here must not prevent opening (e.g. :memory:).
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        try createTables()
        try migrateSchema()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Executes `body` inside a single `BEGIN IMMEDIATE … COMMIT` block (B3).
    /// Must be called while holding `queue` (every public entry point does so).
    /// On body error issues ROLLBACK and rethrows the original error.
    private func withTransaction(_ body: () throws -> Void) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.beginTransactionFailed.nsError(String(cString: sqlite3_errmsg(db)))
        }
        do {
            try body()
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw StoreError.commitTransactionFailed.nsError(msg)
        }
    }

    private func createTables() throws {
        // TODO(B2, deferred breaking migration): url / cookies / headers /
        // referrer / user_agent are persisted here in plaintext. Do NOT log
        // these values anywhere. A future migration should keep only
        // non-sensitive identifiers (hash/null) in the DB and hold secrets in
        // memory/Keychain. Column removal is intentionally NOT done here.
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
            headers TEXT,
            audio_state TEXT
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
                throw StoreError.tableCreationFailed.nsError("Table creation failed: \(msg)")
            }
        }
    }

    private func migrateSchema() throws {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(tasks)", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareTableInfo.nsError() }
            var foundBrowser = false
            var foundSegments = false
            var foundHeaders = false
            var foundAudioState = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 1) {
                    let col = String(cString: text)
                    if col == "browser_info" { foundBrowser = true }
                    if col == "downloaded_segments_count" { foundSegments = true }
                    if col == "headers" { foundHeaders = true }
                    if col == "audio_state" { foundAudioState = true }
                }
            }
            sqlite3_finalize(stmt)
            if !foundBrowser && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN browser_info TEXT", nil, nil, nil) != SQLITE_OK {
                throw StoreError.migrateBrowserInfo.nsError()
            }
            if !foundSegments && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN downloaded_segments_count INTEGER DEFAULT 0", nil, nil, nil) != SQLITE_OK {
                throw StoreError.migrateSegmentsCount.nsError()
            }
            if !foundHeaders && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN headers TEXT", nil, nil, nil) != SQLITE_OK {
                throw StoreError.migrateHeaders.nsError()
            }
            if !foundAudioState && sqlite3_exec(db, "ALTER TABLE tasks ADD COLUMN audio_state TEXT", nil, nil, nil) != SQLITE_OK {
                throw StoreError.migrateAudioState.nsError()
            }
        }
    }

    public func saveTask(_ task: DownloadTask) throws {
        try queue.sync {
            try withTransaction {
                try saveTaskLocked(task)
            }
        }
    }

    public func saveSegments(_ segments: [DownloadSegment]) throws {
        try queue.sync {
            try withTransaction {
                try saveSegmentsLocked(segments)
            }
        }
    }

    /// Atomically persists a task checkpoint together with its segments (B3).
    /// A crash between the two writes can no longer leave `downloaded_bytes`
    /// out of sync with the segment rows.
    public func saveCheckpoint(task: DownloadTask, segments: [DownloadSegment]) throws {
        try queue.sync {
            try withTransaction {
                try saveTaskLocked(task)
                try saveSegmentsLocked(segments)
            }
        }
    }

    private func saveTaskLocked(_ task: DownloadTask) throws {
        let sql = """
        INSERT INTO tasks (
            id, url, filename, destination_folder, total_bytes, downloaded_bytes,
            status, speed, etag, last_modified, accept_ranges, segments_count,
            error_message, created_at, updated_at, referrer, user_agent, cookies, browser_info,
            downloaded_segments_count, headers, audio_state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            browser_info=excluded.browser_info, headers=excluded.headers,
            audio_state=excluded.audio_state;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareSaveTask.nsError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let idStr = task.id.uuidString
        sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (task.url.absoluteString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (task.filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, (task.destinationFolder.path as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, task.totalBytes)
        sqlite3_bind_int64(stmt, 6, task.downloadedBytes)
        sqlite3_bind_text(stmt, 7, (task.status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 8, task.speed)

        if let etag = task.etag {
            sqlite3_bind_text(stmt, 9, (etag as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let lastModified = task.lastModified {
            sqlite3_bind_text(stmt, 10, (lastModified as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        sqlite3_bind_int(stmt, 11, task.acceptRanges ? 1 : 0)
        sqlite3_bind_int(stmt, 12, Int32(task.segmentsCount))

        if let err = task.errorMessage {
            sqlite3_bind_text(stmt, 13, (err as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 13)
        }

        sqlite3_bind_double(stmt, 14, task.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 15, task.updatedAt.timeIntervalSince1970)

        if let ref = task.referrer {
            sqlite3_bind_text(stmt, 16, (ref as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 16)
        }
        if let ua = task.userAgent {
            sqlite3_bind_text(stmt, 17, (ua as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 17)
        }
        if let c = task.cookies {
            sqlite3_bind_text(stmt, 18, (c as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 18)
        }

        if let info = task.browserInfo {
            let encoded = String(data: try JSONEncoder().encode(info), encoding: .utf8)!
            sqlite3_bind_text(stmt, 19, (encoded as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 19) }
        sqlite3_bind_int(stmt, 20, Int32(task.downloadedSegmentsCount))

        if let headers = task.headers, let encoded = try? JSONEncoder().encode(headers), let str = String(data: encoded, encoding: .utf8) {
            sqlite3_bind_text(stmt, 21, (str as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 21) }

        if let audioState = task.audioState {
            sqlite3_bind_text(stmt, 22, (audioState.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 22) }

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.stepSaveTask.nsError(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func getAllTasks() throws -> [DownloadTask] {
        try queue.sync {
            let sql = "SELECT id, url, filename, destination_folder, total_bytes, downloaded_bytes, status, speed, etag, last_modified, accept_ranges, segments_count, error_message, created_at, updated_at, referrer, user_agent, cookies, browser_info, downloaded_segments_count, headers, audio_state FROM tasks ORDER BY created_at DESC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.prepareGetAllTasks.nsError(String(cString: sqlite3_errmsg(db)))
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
                    // B6: tolerant decode — one corrupt browser_info row must not
                    // throw and kill the whole getAllTasks result.
                    let raw = String(cString: text)
                    if let info = try? JSONDecoder().decode(BrowserTaskInfo.self, from: Data(raw.utf8)) {
                        task.browserInfo = info
                    } else {
                        NSLog("SQLiteStore: skipping corrupt browser_info for task %@", id.uuidString)
                    }
                }
                if let text = sqlite3_column_text(stmt, 20) {
                    task.headers = try? JSONDecoder().decode([String: String].self, from: Data(String(cString: text).utf8))
                }
                if let text = sqlite3_column_text(stmt, 21) {
                    task.audioState = MediaAudioState(rawValue: String(cString: text))
                }
                tasks.append(task)
            }
            return tasks
        }
    }

    public func getTask(id: UUID) throws -> DownloadTask? {
        try queue.sync {
            let sql = "SELECT id, url, filename, destination_folder, total_bytes, downloaded_bytes, status, speed, etag, last_modified, accept_ranges, segments_count, error_message, created_at, updated_at, referrer, user_agent, cookies, browser_info, downloaded_segments_count, headers, audio_state FROM tasks WHERE id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.prepareGetTask.nsError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let idStr = id.uuidString
            sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, SQLITE_TRANSIENT)

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
                // B6: tolerant decode — a corrupt browser_info row returns the
                // task without browserInfo instead of throwing.
                let raw = String(cString: text)
                if let info = try? JSONDecoder().decode(BrowserTaskInfo.self, from: Data(raw.utf8)) {
                    task.browserInfo = info
                } else {
                    NSLog("SQLiteStore: skipping corrupt browser_info for task %@", id.uuidString)
                }
            }
            if let text = sqlite3_column_text(stmt, 20) {
                task.headers = try? JSONDecoder().decode([String: String].self, from: Data(String(cString: text).utf8))
            }
            if let text = sqlite3_column_text(stmt, 21) {
                task.audioState = MediaAudioState(rawValue: String(cString: text))
            }
            return task
        }
    }

    public func deleteTask(id: UUID) throws {
        try queue.sync {
            try withTransaction {
                try deleteTaskLocked(id: id)
            }
        }
    }

    private func deleteTaskLocked(id: UUID) throws {
        let idStr = id.uuidString

        let deleteSegSql = "DELETE FROM segments WHERE task_id = ?;"
        var segStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSegSql, -1, &segStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(segStmt, 1, (idStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(segStmt)
            sqlite3_finalize(segStmt)
        }

        let sql = "DELETE FROM tasks WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareDeleteTask.nsError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.stepDeleteTask.nsError(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func deleteFailedTasks() throws {
        try queue.sync {
            try withTransaction {
                let deleteSegmentsSql = "DELETE FROM segments WHERE task_id IN (SELECT id FROM tasks WHERE status = 'failed');"
                var segStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteSegmentsSql, -1, &segStmt, nil) == SQLITE_OK {
                    _ = sqlite3_step(segStmt)
                    sqlite3_finalize(segStmt)
                }

                let sql = "DELETE FROM tasks WHERE status = 'failed';"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw StoreError.prepareDeleteFailedTasks.nsError(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }

                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw StoreError.stepDeleteFailedTasks.nsError(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    public func deleteCompletedAndFailedTasks() throws {
        try queue.sync {
            try withTransaction {
                let deleteSegmentsSql = "DELETE FROM segments WHERE task_id IN (SELECT id FROM tasks WHERE status IN ('completed', 'failed'));"
                var segStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteSegmentsSql, -1, &segStmt, nil) == SQLITE_OK {
                    _ = sqlite3_step(segStmt)
                    sqlite3_finalize(segStmt)
                }

                let sql = "DELETE FROM tasks WHERE status IN ('completed', 'failed');"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw StoreError.prepareDeleteCompletedAndFailedTasks.nsError(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }

                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw StoreError.stepDeleteCompletedAndFailedTasks.nsError(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    private func saveSegmentsLocked(_ segments: [DownloadSegment]) throws {
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
                throw StoreError.prepareSaveSegments.nsError(String(cString: sqlite3_errmsg(db)))
            }

            let idStr = segment.id.uuidString
            let taskIdStr = segment.taskId.uuidString
            sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (taskIdStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(segment.index))
            sqlite3_bind_int64(stmt, 4, segment.startByte)
            sqlite3_bind_int64(stmt, 5, segment.endByte)
            sqlite3_bind_int64(stmt, 6, segment.downloadedBytes)
            sqlite3_bind_text(stmt, 7, (segment.status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmt)
                throw StoreError.stepSaveSegments.nsError(err)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func getSegments(for taskId: UUID) throws -> [DownloadSegment] {
        try queue.sync {
            let sql = "SELECT id, task_id, segment_index, start_byte, end_byte, downloaded_bytes, status FROM segments WHERE task_id = ? ORDER BY segment_index ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.prepareGetSegments.nsError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let taskIdStr = taskId.uuidString
            sqlite3_bind_text(stmt, 1, (taskIdStr as NSString).utf8String, -1, SQLITE_TRANSIENT)

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
