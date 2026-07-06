import Foundation
import SQLite3

struct CodexQuotaSnapshot: Codable {
    let primary: CodexQuota.Window
    let secondary: CodexQuota.Window
    let planType: String
    let model: String
    let timestamp: Date
    let limitId: String?

    var isTrusted: Bool {
        return limitId == "codex"
    }
}

struct CodexFileScanResult: Codable {
    let records: [UsageRecord]
    let latestTrustedQuota: CodexQuotaSnapshot?
    let latestUntrustedQuota: CodexQuotaSnapshot?
    let latestNonzeroPrimaryQuota: CodexQuotaSnapshot?
}

struct CodexUsageScanner {
    private let codexDir: URL
    private let cache = IncrementalCache<CodexFileScanResult>(name: "codex_usage")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.codexDir = home.appendingPathComponent(".codex", isDirectory: true)
    }

    func scan() -> (summary: UsageSummary?, quota: CodexQuota?) {
        guard FileManager.default.fileExists(atPath: codexDir.path) else {
            return (nil, nil)
        }

        let sessionsDir = codexDir.appendingPathComponent("sessions", isDirectory: true)
        let archivedDir = codexDir.appendingPathComponent("archived_sessions", isDirectory: true)

        var allRecords: [UsageRecord] = []
        var validPaths = Set<String>()

        var latestTrustedQuota: CodexQuotaSnapshot?
        var latestUntrustedQuota: CodexQuotaSnapshot?
        var latestNonzeroPrimaryQuota: CodexQuotaSnapshot?

        for dir in [sessionsDir, archivedDir] {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }

                validPaths.insert(url.path)

                if !cache.needsRescan(url) {
                    if let cached = cache.get(url) {
                        allRecords.append(contentsOf: cached.records)

                        if let trusted = cached.latestTrustedQuota {
                            if latestTrustedQuota == nil || trusted.timestamp > latestTrustedQuota!.timestamp {
                                latestTrustedQuota = trusted
                            }
                        }
                        if let untrusted = cached.latestUntrustedQuota {
                            if latestUntrustedQuota == nil || untrusted.timestamp > latestUntrustedQuota!.timestamp {
                                latestUntrustedQuota = untrusted
                            }
                        }
                        if let nonzero = cached.latestNonzeroPrimaryQuota {
                            if latestNonzeroPrimaryQuota == nil || nonzero.timestamp > latestNonzeroPrimaryQuota!.timestamp {
                                latestNonzeroPrimaryQuota = nonzero
                            }
                        }
                    }
                    continue
                }

                guard let signature = FileSignature(url: url) else { continue }
                let scanResult = parseJSONL(url)

                cache.set(url, signature: signature, data: scanResult)
                allRecords.append(contentsOf: scanResult.records)

                if let trusted = scanResult.latestTrustedQuota {
                    if latestTrustedQuota == nil || trusted.timestamp > latestTrustedQuota!.timestamp {
                        latestTrustedQuota = trusted
                    }
                }
                if let untrusted = scanResult.latestUntrustedQuota {
                    if latestUntrustedQuota == nil || untrusted.timestamp > latestUntrustedQuota!.timestamp {
                        latestUntrustedQuota = untrusted
                    }
                }
                if let nonzero = scanResult.latestNonzeroPrimaryQuota {
                    if latestNonzeroPrimaryQuota == nil || nonzero.timestamp > latestNonzeroPrimaryQuota!.timestamp {
                        latestNonzeroPrimaryQuota = nonzero
                    }
                }
            }
        }

        cache.cleanup(validPaths: validPaths)
        cache.save()

        let summary = aggregate(allRecords)

        let codexQuota: CodexQuota?
        if let trusted = latestTrustedQuota {
            codexQuota = CodexQuota(
                planType: trusted.planType,
                model: trusted.model,
                primary: trusted.primary,
                secondary: trusted.secondary
            )
        } else if let untrusted = latestUntrustedQuota {
            codexQuota = CodexQuota(
                planType: untrusted.planType,
                model: untrusted.model,
                primary: untrusted.primary,
                secondary: untrusted.secondary
            )
        } else {
            codexQuota = nil
        }

        return (summary, codexQuota)
    }

    // MARK: - Private

    private func parseJSONL(_ url: URL) -> CodexFileScanResult {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return CodexFileScanResult(records: [], latestTrustedQuota: nil, latestUntrustedQuota: nil, latestNonzeroPrimaryQuota: nil)
        }

        var records: [UsageRecord] = []
        var latestTrustedQuota: CodexQuotaSnapshot?
        var latestUntrustedQuota: CodexQuotaSnapshot?
        var latestNonzeroPrimaryQuota: CodexQuotaSnapshot?

        let configPath = codexDir.appendingPathComponent("config.toml")
        let defaultModel = readTomlValue(from: configPath, key: "model") ?? "gpt-5.5"
        let defaultServiceTier = readTomlValue(from: configPath, key: "service_tier") ?? "default"

        var currentModel = defaultModel
        var currentServiceTier = defaultServiceTier

        let lines = data.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8) else {
                continue
            }

            do {
                let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                guard let json = json else { continue }

                let type = json["type"] as? String

                if type == "turn_context",
                   let payload = json["payload"] as? [String: Any] {
                    if let model = payload["model"] as? String {
                        currentModel = model
                    }
                    if let tier = payload["service_tier"] as? String {
                        currentServiceTier = tier
                    }
                    continue
                }

                if type == "event_msg",
                   let payload = json["payload"] as? [String: Any],
                   payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let lastUsage = info["last_token_usage"] as? [String: Any] {

                    guard let timestampStr = json["timestamp"] as? String,
                          let timestamp = parseISO8601(timestampStr) else {
                        continue
                    }

                    let input = lastUsage["input_tokens"] as? Int ?? 0
                    let cachedInput = lastUsage["cached_input_tokens"] as? Int ?? 0
                    let output = lastUsage["output_tokens"] as? Int ?? 0
                    let reasoning = lastUsage["reasoning_output_tokens"] as? Int ?? 0
                    let total = lastUsage["total_tokens"] as? Int ?? (input + output + reasoning)

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
                        output: output,
                        reasoning: reasoning,
                        model: currentModel,
                        serviceTier: currentServiceTier
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
                       let primary = rateLimits["primary"] as? [String: Any],
                       let secondary = rateLimits["secondary"] as? [String: Any],
                       let planType = rateLimits["plan_type"] as? String {

                        let limitId = rateLimits["limit_id"] as? String

                        let primaryUsed = primary["used_percent"] as? Double ?? 0
                        let primaryWindowMinutes = primary["window_minutes"] as? Int ?? 300
                        let primaryResetsAt = primary["resets_at"] as? TimeInterval ?? 0

                        let secondaryUsed = secondary["used_percent"] as? Double ?? 0
                        let secondaryWindowMinutes = secondary["window_minutes"] as? Int ?? 10080
                        let secondaryResetsAt = secondary["resets_at"] as? TimeInterval ?? 0

                        let primaryWindow = CodexQuota.Window(
                            usedPercent: primaryUsed,
                            windowMinutes: primaryWindowMinutes,
                            resetsAt: Date(timeIntervalSince1970: primaryResetsAt)
                        )

                        let secondaryWindow = CodexQuota.Window(
                            usedPercent: secondaryUsed,
                            windowMinutes: secondaryWindowMinutes,
                            resetsAt: Date(timeIntervalSince1970: secondaryResetsAt)
                        )

                        let snapshot = CodexQuotaSnapshot(
                            primary: primaryWindow,
                            secondary: secondaryWindow,
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

                        if snapshot.isTrusted && primaryUsed > 0 {
                            if latestNonzeroPrimaryQuota == nil || snapshot.timestamp > latestNonzeroPrimaryQuota!.timestamp {
                                latestNonzeroPrimaryQuota = snapshot
                            }
                        }
                    }
                }
            } catch {
                continue
            }
        }

        return CodexFileScanResult(
            records: records,
            latestTrustedQuota: latestTrustedQuota,
            latestUntrustedQuota: latestUntrustedQuota,
            latestNonzeroPrimaryQuota: latestNonzeroPrimaryQuota
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
