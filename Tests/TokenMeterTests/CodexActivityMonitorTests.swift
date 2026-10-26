import SQLite3
import XCTest
@testable import TokenMeter

final class CodexActivityMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSession(_ directory: URL, name: String, age: TimeInterval) throws {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Intentionally not JSON: activity detection only needs metadata.
        try Data("not a transcript".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    func testRecentSessionAndArchivedSessionWritesAreActiveWithoutParsingContents() async throws {
        for name in ["sessions/2026/10/26/rollout.jsonl", "archived_sessions/rollout.jsonl"] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeSession(root, name: name, age: 299)
            let active = await CodexActivityMonitor(directory: root).isActive(now: now)
            XCTAssertTrue(active, name)
        }
    }

    func testStaleFutureNonSessionAndHousekeepingFilesAreIgnored() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root, name: "sessions/old.jsonl", age: 300)
        try writeSession(root, name: "sessions/future.jsonl", age: -1)
        try writeSession(root, name: "sessions/recent.txt", age: 0)
        try writeSession(root, name: "state_5.sqlite-wal", age: 0)
        try writeSession(root, name: "logs_2.sqlite-wal", age: 0)
        let active = await CodexActivityMonitor(directory: root).isActive(now: now)
        XCTAssertFalse(active)
    }

    func testActivityExpiresAndResumesAfterLocalWrite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = CodexActivityMonitor(directory: root)
        try writeSession(root, name: "sessions/rollout.jsonl", age: 0)
        let initial = await monitor.isActive(now: now)
        let expired = await monitor.isActive(now: now.addingTimeInterval(300))
        XCTAssertTrue(initial)
        XCTAssertFalse(expired)
        try writeSession(root, name: "sessions/rollout.jsonl", age: -300)
        let resumed = await monitor.isActive(now: now.addingTimeInterval(300))
        XCTAssertTrue(resumed)
    }

    func testOnlyRecentThreadScopedWorkCountsInLiveWAL() async throws {
        for (target, thread, age, expected): (String, String?, Int, Bool) in [
            ("codex_core::stream_events_utils", "test-thread", 10, true),
            ("codex_core::session::turn", "test-thread", 299, true),
            ("codex_core::tools::parallel", "test-thread", 0, true),
            ("codex_core::codex", "test-thread", 1, true),
            ("codex_core::stream_events_utils", nil, 0, false),
            ("codex_core::session::turn", "", 0, false),
            ("codex_app_server", "test-thread", 0, false),
            ("codex_core::world_state", "test-thread", 0, false),
            ("codex_core::session::turn", "test-thread", 300, false),
            ("codex_core::session::turn", "test-thread", -1, false),
        ] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("logs_2.sqlite")
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            // Synthetic fixture only; keep the writer open to exercise WAL visibility.
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE logs (ts INTEGER, target TEXT, thread_id TEXT); CREATE INDEX idx_logs_ts ON logs(ts DESC);", nil, nil, nil), SQLITE_OK)
            let threadSQL = thread.map { "'\($0)'" } ?? "NULL"
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO logs VALUES (\(Int(now.timeIntervalSince1970) - age), '\(target)', \(threadSQL))", nil, nil, nil), SQLITE_OK)
            let before = sqlite3_total_changes(db)
            let active = await CodexActivityMonitor(directory: root).isActive(now: now)
            XCTAssertEqual(active, expected, "\(target), \(thread ?? "nil"), \(age)")
            XCTAssertEqual(sqlite3_total_changes(db), before)
        }
    }

    func testMissingCorruptAndIncompatibleDatabaseFailQuietly() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = CodexActivityMonitor(directory: root)
        let missing = await monitor.isActive(now: now)
        XCTAssertFalse(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("logs_2.sqlite").path))
        try Data("not sqlite".utf8).write(to: root.appendingPathComponent("logs_2.sqlite"))
        let corrupt = await monitor.isActive(now: now)
        XCTAssertFalse(corrupt)
        let otherRoot = try directory()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(otherRoot.appendingPathComponent("logs_2.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE logs (old_schema INTEGER)", nil, nil, nil), SQLITE_OK)
        let incompatible = await CodexActivityMonitor(directory: otherRoot).isActive(now: now)
        XCTAssertFalse(incompatible)
    }
}
