import Foundation

struct ClaudeUsageScanner {
    private let projectsDir: URL
    private let cache = IncrementalCache<[UsageRecord]>(name: "claude_usage_v2")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func scan() -> UsageSummary? {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var allRecords: [UsageRecord] = []
        var seenMessageIds = Set<String>()
        var validPaths = Set<String>()

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }

            validPaths.insert(url.path)

            if !cache.needsRescan(url) {
                if let cached = cache.get(url) {
                    for record in cached where !seenMessageIds.contains(record.messageId) {
                        allRecords.append(record)
                        seenMessageIds.insert(record.messageId)
                    }
                }
                continue
            }

            guard let signature = FileSignature(url: url) else { continue }
            let records = parseJSONL(url)

            cache.set(url, signature: signature, data: records)

            for record in records where !seenMessageIds.contains(record.messageId) {
                allRecords.append(record)
                seenMessageIds.insert(record.messageId)
            }
        }

        cache.cleanup(validPaths: validPaths)
        cache.save()

        return aggregate(allRecords)
    }

    // MARK: - Private

    private func parseJSONL(_ url: URL) -> [UsageRecord] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var records: [UsageRecord] = []
        let lines = data.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8) else {
                continue
            }

            do {
                let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                guard let json = json else { continue }

                guard json["type"] as? String == "assistant" else { continue }

                guard let message = json["message"] as? [String: Any],
                      let messageId = message["id"] as? String,
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                guard let timestampStr = json["timestamp"] as? String,
                      let timestamp = parseISO8601(timestampStr) else {
                    continue
                }

                let model = message["model"] as? String ?? ""

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0

                var cacheWrite5m = 0
                var cacheWrite1h = 0

                if let cacheCreation = usage["cache_creation"] as? [String: Any] {
                    cacheWrite5m = cacheCreation["ephemeral_5m_input_tokens"] as? Int ?? 0
                    cacheWrite1h = cacheCreation["ephemeral_1h_input_tokens"] as? Int ?? 0
                }

                if cacheWrite5m == 0 && cacheWrite1h == 0 {
                    cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
                }

                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

                let tokenUsage = UsageRecord.TokenUsage(
                    input: input,
                    output: output,
                    cacheWrite5m: cacheWrite5m,
                    cacheWrite1h: cacheWrite1h,
                    cacheRead: cacheRead
                )

                let costCNY = PricingEngine.shared.calculateCNY(usage: tokenUsage, model: model)

                let record = UsageRecord(
                    messageId: messageId,
                    timestamp: timestamp,
                    model: model,
                    tokens: tokenUsage,
                    costCNY: costCNY,
                    source: .claude
                )

                records.append(record)
            } catch {
                continue
            }
        }

        return records
    }

    private func aggregate(_ records: [UsageRecord]) -> UsageSummary {
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

        let weekDays = Array(dailyUsages.prefix(7))
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

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: str) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
