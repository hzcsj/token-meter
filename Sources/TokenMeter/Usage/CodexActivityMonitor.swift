import Foundation
import SQLite3

/// A local-only heuristic, independent of quota reads and the expensive usage scan.
/// Recent session writes or thread-scoped inference/tool logs count as activity;
/// a running desktop app and threadless app-server housekeeping do not.
actor CodexActivityMonitor {
    private let directory: URL
    static let activityWindow: TimeInterval = 300

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)) {
        self.directory = directory
    }

    func isActive(now: Date = Date()) -> Bool {
        let since = now.addingTimeInterval(-Self.activityWindow)
        for name in ["sessions", "archived_sessions"] {
            let root = directory.appendingPathComponent(name, isDirectory: true)
            guard let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
                if modified > since && modified <= now { return true }
            }
        }
        return hasRecentThreadActivity(since: since, now: now)
    }

    private func hasRecentThreadActivity(since: Date, now: Date) -> Bool {
        let file = directory.appendingPathComponent("logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        // Bound work even if an older/incompatible database has no time index.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        let deadlinePointer = UnsafeMutablePointer<TimeInterval>.allocate(capacity: 1)
        deadlinePointer.initialize(to: deadline)
        defer { deadlinePointer.deinitialize(count: 1); deadlinePointer.deallocate() }
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 1 }
            let deadline = context.assumingMemoryBound(to: TimeInterval.self).pointee
            return ProcessInfo.processInfo.systemUptime >= deadline ? 1 : 0
        }, deadlinePointer)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        let query = """
            SELECT 1 FROM logs
            WHERE ts > ? AND ts <= ? AND thread_id IS NOT NULL AND thread_id != ''
              AND (target IN ('codex_core::stream_events_utils', 'codex_core::session::turn',
                              'codex_core::codex') OR target LIKE 'codex_core::tools::%')
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
