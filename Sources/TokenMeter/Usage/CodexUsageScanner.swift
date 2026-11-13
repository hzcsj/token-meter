import Foundation
import SQLite3

struct CodexQuotaSnapshot: Codable {
    let windows: [CodexQuota.Window]
    let planType: String
    let model: String
    let timestamp: Date
    let limitId: String?

    var isTrusted: Bool {
        limitId == "codex" && !windows.isEmpty && windows.allSatisfy {
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) &&
            (1...525_600).contains($0.windowMinutes) &&
            $0.resetsAt.timeIntervalSince1970.isFinite && $0.resetsAt > timestamp
        } && Set(windows.map(\.windowMinutes)).count == windows.count
    }
}

struct CodexFileScanResult: Codable {
    let records: [UsageRecord]
    let latestTrustedQuota: CodexQuotaSnapshot?
    let latestUntrustedQuota: CodexQuotaSnapshot?
    let latestNonzeroPrimaryQuota: CodexQuotaSnapshot?
    let threadId: String?
}

func resolveCodexQuota(
    trusted: CodexQuotaSnapshot?,
    untrusted: CodexQuotaSnapshot?
) -> CodexQuota? {
    if let trusted {
        guard trusted.isTrusted, !["free", "go"].contains(trusted.planType.lowercased()) else { return nil }
        return CodexQuota(
            planType: trusted.planType,
            model: trusted.model,
            windows: trusted.windows,
            observedAt: trusted.timestamp,
            limitId: trusted.limitId
        )
    }

    // An auxiliary bucket is a separate allowance, not a fresher main quota.
    return nil
}

struct CodexUsageScanner {
    private let codexDir: URL
    private let cache: IncrementalCache<CodexFileScanResult>

    init(codexDir: URL? = nil, cacheDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.codexDir = codexDir ?? home.appendingPathComponent(".codex", isDirectory: true)
        self.cache = IncrementalCache(name: "codex_usage_v7_\(PricingEngine.shared.cacheKey)",
                                      directory: cacheDirectory)
    }

    func scan() -> (summary: UsageSummary?, quota: CodexQuota?) {
        guard FileManager.default.fileExists(atPath: codexDir.path) else {
            return (nil, nil)
        }

        let sessionsDir = codexDir.appendingPathComponent("sessions", isDirectory: true)
        let archivedDir = codexDir.appendingPathComponent("archived_sessions", isDirectory: true)

        var allRecords: [UsageRecord] = []
        var validPaths = Set<String>()
        var jsonlThreadIds = Set<String>()

        var latestTrustedQuota: CodexQuotaSnapshot?
        var latestUntrustedQuota: CodexQuotaSnapshot?
        var latestNonzeroPrimaryQuota: CodexQuotaSnapshot?

        // A rollout can briefly exist in both formats/locations during archival.
        // Group by logical filename, prefer the live plain file, and count once.
        var candidates: [String: [URL]] = [:]
        var complete = true
        for dir in [sessionsDir, archivedDir] {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in complete = false; return true }
            ) else { complete = false; continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.zst") else { continue }
                let name = url.pathExtension == "zst"
                    ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                candidates[name, default: []].append(url)
                validPaths.insert(url.path)
            }
        }

        for name in candidates.keys.sorted() {
            let urls = candidates[name]!.sorted {
                if ($0.pathExtension == "jsonl") != ($1.pathExtension == "jsonl") {
                    return $0.pathExtension == "jsonl"
                }
                return $0.path < $1.path
            }
            var selected: CodexFileScanResult?
            for url in urls {
                if !cache.needsRescan(url), let cached = cache.get(url) {
                    selected = cached
                    break
                }
                guard let signature = FileSignature(url: url),
                      let result = try? autoreleasepool(invoking: { try parseJSONL(url) }) else { continue }
                // Never mark a partially written or concurrently replaced file as cached.
                if FileSignature(url: url) == signature {
                    cache.set(url, signature: signature, data: result)
                }
                selected = result
                break
            }
            // A damaged/truncated archive must not replace good data with an empty entry.
            if selected == nil { selected = urls.compactMap { cache.get($0) }.first }
            guard let result = selected else { complete = false; continue }
            allRecords.append(contentsOf: result.records)
            if let tid = result.threadId { jsonlThreadIds.insert(tid) }
            if let quota = result.latestTrustedQuota,
               latestTrustedQuota == nil || quota.timestamp > latestTrustedQuota!.timestamp {
                latestTrustedQuota = quota
            }
            if let quota = result.latestUntrustedQuota,
               latestUntrustedQuota == nil || quota.timestamp > latestUntrustedQuota!.timestamp {
                latestUntrustedQuota = quota
            }
            if let quota = result.latestNonzeroPrimaryQuota,
               latestNonzeroPrimaryQuota == nil || quota.timestamp > latestNonzeroPrimaryQuota!.timestamp {
                latestNonzeroPrimaryQuota = quota
            }
        }

        if complete { cache.cleanup(validPaths: validPaths) }
        cache.save()
        // Keep the previous UI snapshot if a source cannot be read. Retry next scan.
        guard complete else { return (nil, nil) }

        // Supplement with logs-only side/temporary chat records
        let logsOnlyRecords = scanLogsOnlyRecords(knownJSONLThreadIds: jsonlThreadIds, jsonlRecords: allRecords)
        allRecords.append(contentsOf: logsOnlyRecords)

        let summary = aggregate(allRecords)

        let codexQuota = resolveCodexQuota(
            trusted: latestTrustedQuota,
            untrusted: latestUntrustedQuota
        )

        return (summary, codexQuota)
    }

    // MARK: - Private

    func parseJSONL(_ url: URL) throws -> CodexFileScanResult {

        var records: [UsageRecord] = []
        var latestTrustedQuota: CodexQuotaSnapshot?
        var latestUntrustedQuota: CodexQuotaSnapshot?
        var latestNonzeroPrimaryQuota: CodexQuotaSnapshot?
        var threadId: String?

        let configPath = codexDir.appendingPathComponent("config.toml")
        let defaultModel = readTomlValue(from: configPath, key: "model") ?? "gpt-5.6-sol"
        let defaultServiceTier = readTomlValue(from: configPath, key: "service_tier") ?? "default"

        var currentModel = defaultModel
        var currentServiceTier = defaultServiceTier
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeDate = ISO8601DateFormatter()
        wholeDate.formatOptions = [.withInternetDateTime]

        let relevant = ["\"token_count\"", "\"session_meta\"", "\"turn_context\""].map { Data($0.utf8) }
        try JSONLStreamReader().read(url) { jsonData in
            guard relevant.contains(where: { jsonData.range(of: $0) != nil }) else { return }

            do {
                let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                guard let json = json else { return }

                let type = json["type"] as? String

                if type == "session_meta",
                   let payload = json["payload"] as? [String: Any],
                   let tid = payload["id"] as? String, !tid.isEmpty {
                    threadId = tid
                    return
                }

                if type == "turn_context",
                   let payload = json["payload"] as? [String: Any] {
                    if let model = payload["model"] as? String {
                        currentModel = model
                    }
                    if let tier = payload["service_tier"] as? String {
                        currentServiceTier = tier
                    }
                    return
                }

                if type == "event_msg",
                   let payload = json["payload"] as? [String: Any],
                   payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let lastUsage = info["last_token_usage"] as? [String: Any] {

                    guard let timestampStr = json["timestamp"] as? String,
                          let timestamp = fractionalDate.date(from: timestampStr) ?? wholeDate.date(from: timestampStr) else {
                        return
                    }

                    let input = lastUsage["input_tokens"] as? Int ?? 0
                    let cachedInput = lastUsage["cached_input_tokens"] as? Int ?? 0
                    let cacheWriteInput = lastUsage["cache_write_input_tokens"] as? Int ?? 0
                    let output = lastUsage["output_tokens"] as? Int ?? 0
                    let reasoning = lastUsage["reasoning_output_tokens"] as? Int ?? 0
                    // Codex output_tokens already includes reasoning_output_tokens.
                    let total = lastUsage["total_tokens"] as? Int ?? (input + output)

                    let tokenUsage = UsageRecord.TokenUsage(
                        input: total,
                        output: 0,
                        cacheWrite5m: 0,
                        cacheWrite1h: 0,
                        cacheRead: 0
                    )

                    let costCNY = PricingEngine.shared.calculateCodexCNY(
                        input: input,
                        cachedInput: cachedInput,
                        cacheWriteInput: cacheWriteInput,
                        output: output,
                        reasoning: reasoning,
                        model: currentModel,
                        serviceTier: currentServiceTier,
                        at: timestamp
                    )

                    let record = UsageRecord(
                        messageId: UUID().uuidString,
                        timestamp: timestamp,
                        model: currentModel,
                        tokens: tokenUsage,
                        costCNY: costCNY,
                        source: .codex
                    )

                    records.append(record)

                    if let rateLimits = payload["rate_limits"] as? [String: Any],
                       let planType = rateLimits["plan_type"] as? String {

                        let limitId = rateLimits["limit_id"] as? String

                        var windows: [CodexQuota.Window] = []
                        var validWindows = true
                        for slot in ["primary", "secondary"] {
                            guard let value = rateLimits[slot], !(value is NSNull) else { continue }
                            guard let w = value as? [String: Any],
                                  let used = w["used_percent"] as? Double,
                                  let winMin = w["window_minutes"] as? Int,
                                  let resetsAt = w["resets_at"] as? TimeInterval else {
                                validWindows = false
                                break
                            }
                            windows.append(CodexQuota.Window(
                                sourceSlot: slot,
                                usedPercent: used,
                                windowMinutes: winMin,
                                resetsAt: Date(timeIntervalSince1970: resetsAt)
                            ))
                        }
                        guard validWindows else { return }
                        windows.sort { $0.windowMinutes < $1.windowMinutes }

                        let snapshot = CodexQuotaSnapshot(
                            windows: windows,
                            planType: planType,
                            model: currentModel,
                            timestamp: timestamp,
                            limitId: limitId
                        )

                        if snapshot.isTrusted {
                            if latestTrustedQuota == nil || snapshot.timestamp > latestTrustedQuota!.timestamp {
                                latestTrustedQuota = snapshot
                            }
                        } else if limitId?.hasPrefix("codex") == true {
                            if latestUntrustedQuota == nil || snapshot.timestamp > latestUntrustedQuota!.timestamp {
                                latestUntrustedQuota = snapshot
                            }
                        }

                        let hasNonzeroUsage = windows.contains { $0.usedPercent > 0 }
                        if snapshot.isTrusted && hasNonzeroUsage {
                            if latestNonzeroPrimaryQuota == nil || snapshot.timestamp > latestNonzeroPrimaryQuota!.timestamp {
                                latestNonzeroPrimaryQuota = snapshot
                            }
                        }
                    }
                }
            } catch {
                return
            }
        }

        return CodexFileScanResult(
            records: records,
            latestTrustedQuota: latestTrustedQuota,
            latestUntrustedQuota: latestUntrustedQuota,
            latestNonzeroPrimaryQuota: latestNonzeroPrimaryQuota,
            threadId: threadId
        )
    }

    private func aggregate(_ records: [UsageRecord]) -> UsageSummary? {
        guard !records.isEmpty else { return nil }

        var byDate: [String: [UsageRecord]] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        for record in records {
            let dateKey = formatter.string(from: record.timestamp)
            byDate[dateKey, default: []].append(record)
        }

        var dailyUsages: [DailyUsage] = []
        for (date, dayRecords) in byDate {
            let tokens = dayRecords.reduce(0) { $0 + $1.tokens.total }
            let cost = dayRecords.reduce(0.0) { $0 + $1.costCNY }
            let count = dayRecords.count

            dailyUsages.append(DailyUsage(
                date: date,
                tokens: tokens,
                costCNY: cost,
                messageCount: count
            ))
        }

        dailyUsages.sort { $0.date > $1.date }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let weekStartKey = formatter.string(from: weekStart)
        let weekDays = dailyUsages.filter { $0.date >= weekStartKey }
        let weekTotal = DailyUsage(
            date: "week",
            tokens: weekDays.reduce(0) { $0 + $1.tokens },
            costCNY: weekDays.reduce(0.0) { $0 + $1.costCNY },
            messageCount: weekDays.reduce(0) { $0 + $1.messageCount }
        )

        let monthRecords = records.filter { $0.timestamp >= monthStart }

        let monthTotal = DailyUsage(
            date: "month",
            tokens: monthRecords.reduce(0) { $0 + $1.tokens.total },
            costCNY: monthRecords.reduce(0.0) { $0 + $1.costCNY },
            messageCount: monthRecords.count
        )

        let allTimeTotal = DailyUsage(
            date: "all",
            tokens: records.reduce(0) { $0 + $1.tokens.total },
            costCNY: records.reduce(0.0) { $0 + $1.costCNY },
            messageCount: records.count
        )

        return UsageSummary(
            byDay: dailyUsages,
            weekTotal: weekTotal,
            monthTotal: monthTotal,
            allTimeTotal: allTimeTotal
        )
    }

    private func readTomlValue(from url: URL, key: String) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) =") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
            }
        }

        return nil
    }

    // MARK: - Logs-only supplemental scan

    private func scanLogsOnlyRecords(knownJSONLThreadIds: Set<String>, jsonlRecords: [UsageRecord]) -> [UsageRecord] {
        let logsDbPath = codexDir.appendingPathComponent("logs_2.sqlite").path
        guard FileManager.default.fileExists(atPath: logsDbPath) else { return [] }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file:\(logsDbPath)?mode=ro", &db, flags, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT ts, thread_id, feedback_log_body FROM logs
            WHERE feedback_log_body LIKE '%: post sampling token usage turn_id=%'
            ORDER BY ts ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let dayRates = computeDailyEffectiveRates(from: jsonlRecords)
        let fallbackRate = 5.0 / 1_000_000.0 * 7.0

        let configPath = codexDir.appendingPathComponent("config.toml")
        let defaultModel = readTomlValue(from: configPath, key: "model") ?? "gpt-5.6-sol"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        var records: [UsageRecord] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let threadIdPtr = sqlite3_column_text(stmt, 1)
            let bodyPtr = sqlite3_column_text(stmt, 2)

            let threadId = threadIdPtr.map { String(cString: $0) } ?? ""
            let body = bodyPtr.map { String(cString: $0) } ?? ""

            if body.contains(": ToolCall:") { continue }

            guard !threadId.isEmpty else { continue }
            guard !knownJSONLThreadIds.contains(threadId) else { continue }

            guard let totalTokens = extractInt(after: "total_usage_tokens=", in: body), totalTokens > 0 else {
                continue
            }

            let timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
            let dateKey = dateFormatter.string(from: timestamp)
            let rate = dayRates[dateKey] ?? fallbackRate
            let costCNY = Double(totalTokens) * rate

            let model = extractValue(after: "model=", in: body) ?? defaultModel

            let tokenUsage = UsageRecord.TokenUsage(
                input: totalTokens,
                output: 0,
                cacheWrite5m: 0,
                cacheWrite1h: 0,
                cacheRead: 0
            )

            let messageId = "\(threadId)-\(ts)-\(totalTokens)"

            let record = UsageRecord(
                messageId: messageId,
                timestamp: timestamp,
                model: model,
                tokens: tokenUsage,
                costCNY: costCNY,
                source: .codex
            )
            records.append(record)
        }

        return records
    }

    private func computeDailyEffectiveRates(from records: [UsageRecord]) -> [String: Double] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        var dayTokens: [String: Int] = [:]
        var dayCost: [String: Double] = [:]

        for record in records where record.source == .codex {
            let dateKey = dateFormatter.string(from: record.timestamp)
            dayTokens[dateKey, default: 0] += record.tokens.total
            dayCost[dateKey, default: 0.0] += record.costCNY
        }

        var rates: [String: Double] = [:]
        for (day, tokens) in dayTokens {
            let cost = dayCost[day] ?? 0
            if tokens > 0 && cost > 0 {
                rates[day] = cost / Double(tokens)
            }
        }
        return rates
    }

    private func extractInt(after prefix: String, in string: String) -> Int? {
        guard let range = string.range(of: prefix) else { return nil }
        let start = range.upperBound
        var end = start
        while end < string.endIndex && string[end].isNumber {
            end = string.index(after: end)
        }
        guard start < end else { return nil }
        return Int(string[start..<end])
    }

    private func extractValue(after prefix: String, in string: String) -> String? {
        guard let range = string.range(of: prefix) else { return nil }
        let start = range.upperBound
        var end = start
        while end < string.endIndex && !string[end].isWhitespace && string[end] != "}" && string[end] != "," {
            end = string.index(after: end)
        }
        guard start < end else { return nil }
        return String(string[start..<end])
    }
}
