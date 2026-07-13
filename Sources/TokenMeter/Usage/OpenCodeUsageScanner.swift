import Foundation
import SQLite3

struct OpenCodeUsageScanner {
    private let databaseURL: URL

    init(
        databaseURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else if let overridePath = environment["OPENCODE_DB_PATH"], !overridePath.isEmpty {
            self.databaseURL = URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.databaseURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        }
    }

    func scan() -> UsageSummary? {
        aggregate(scanRecords())
    }

    func scanRecords() -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(readOnlyURI, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 1_000)

        let query = "SELECT id, time_created, data FROM message ORDER BY time_created ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var records: [UsageRecord] = []
        var seenMessageIds = Set<String>()
        let decoder = JSONDecoder()

        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL,
                  sqlite3_column_type(statement, 2) != SQLITE_NULL,
                  let idPointer = sqlite3_column_text(statement, 0),
                  let dataPointer = sqlite3_column_text(statement, 2) else {
                continue
            }

            let messageId = String(cString: idPointer)
            guard !messageId.isEmpty, !seenMessageIds.contains(messageId) else {
                continue
            }

            let dataLength = Int(sqlite3_column_bytes(statement, 2))
            let jsonData = Data(bytes: dataPointer, count: dataLength)
            guard let message = try? decoder.decode(OpenCodeMessageData.self, from: jsonData),
                  message.role == "assistant",
                  let tokens = message.tokens else {
                continue
            }

            let input = max(0, tokens.input ?? 0)
            let output = max(0, tokens.output ?? 0) + max(0, tokens.reasoning ?? 0)
            let cacheRead = max(0, tokens.cache?.read ?? 0)

            // OpenCode does not distinguish 5m from 1h cache writes. Current
            // Qwen 3.7 Max prices are identical, so all writes use the 5m slot.
            let cacheWrite5m = max(0, tokens.cache?.write ?? 0)

            let tokenUsage = UsageRecord.TokenUsage(
                input: input,
                output: output,
                cacheWrite5m: cacheWrite5m,
                cacheWrite1h: 0,
                cacheRead: cacheRead
            )

            let model = message.modelID ?? ""
            let timestampMilliseconds = sqlite3_column_int64(statement, 1)
            let timestamp = Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1_000.0)

            records.append(UsageRecord(
                messageId: messageId,
                timestamp: timestamp,
                model: model,
                tokens: tokenUsage,
                costCNY: PricingEngine.shared.calculateCNY(usage: tokenUsage, model: model),
                source: .opencode
            ))
            seenMessageIds.insert(messageId)
        }

        return records
    }

    private var readOnlyURI: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let path = databaseURL.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? databaseURL.path
        return "file:\(path)?mode=ro"
    }

    private func aggregate(_ records: [UsageRecord]) -> UsageSummary? {
        guard !records.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        var byDate: [String: DailyUsage] = [:]
        for record in records {
            let date = formatter.string(from: record.timestamp)
            let existing = byDate[date]
            byDate[date] = DailyUsage(
                date: date,
                tokens: (existing?.tokens ?? 0) + record.tokens.total,
                costCNY: (existing?.costCNY ?? 0) + record.costCNY,
                messageCount: (existing?.messageCount ?? 0) + 1
            )
        }

        let byDay = byDate.values.sorted { $0.date > $1.date }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        let weekRecords = records.filter { $0.timestamp >= weekStart }
        let monthRecords = records.filter { $0.timestamp >= monthStart }

        return UsageSummary(
            byDay: byDay,
            weekTotal: total(records: weekRecords, date: "week"),
            monthTotal: total(records: monthRecords, date: "month"),
            allTimeTotal: total(records: records, date: "all")
        )
    }

    private func total(records: [UsageRecord], date: String) -> DailyUsage {
        DailyUsage(
            date: date,
            tokens: records.reduce(0) { $0 + $1.tokens.total },
            costCNY: records.reduce(0.0) { $0 + $1.costCNY },
            messageCount: records.count
        )
    }
}

private struct OpenCodeMessageData: Decodable {
    let role: String?
    let modelID: String?
    let providerID: String?
    let tokens: Tokens?
    let cost: Double?

    struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: Cache?

        struct Cache: Decodable {
            let read: Int?
            let write: Int?
        }
    }
}
