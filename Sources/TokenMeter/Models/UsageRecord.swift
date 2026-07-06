import Foundation

struct UsageRecord: Codable, Equatable {
    let messageId: String
    let timestamp: Date
    let model: String
    let tokens: TokenUsage
    let costCNY: Double
    let source: Source

    enum Source: String, Codable {
        case claude
        case codex
    }

    struct TokenUsage: Codable, Equatable {
        let input: Int
        let output: Int
        let cacheWrite5m: Int
        let cacheWrite1h: Int
        let cacheRead: Int

        var total: Int {
            input + output + cacheWrite5m + cacheWrite1h + cacheRead
        }
    }
}

struct DailyUsage: Codable, Equatable {
    let date: String  // "YYYY-MM-DD"
    let tokens: Int
    let costCNY: Double
    let messageCount: Int

    var label: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: date) else { return date }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: target, to: today).day ?? 0

        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekdayIndex = calendar.component(.weekday, from: date) - 1
        let weekday = weekdays[weekdayIndex]

        formatter.dateFormat = "MM-dd"
        let dateStr = formatter.string(from: date)

        switch days {
        case 0: return "今日 (\(weekday))"
        case 1: return "昨日 (\(weekday))"
        default: return "\(dateStr) (\(weekday))"
        }
    }
}

struct UsageSummary: Codable, Equatable {
    let byDay: [DailyUsage]
    let weekTotal: DailyUsage
    let monthTotal: DailyUsage
    let allTimeTotal: DailyUsage

    var today: DailyUsage? {
        byDay.first
    }
}

struct CodexQuota: Codable, Equatable {
    let planType: String
    let model: String
    let primary: Window   // 5h
    let secondary: Window // 7d

    struct Window: Codable, Equatable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date

        var remainingPercent: Double {
            100.0 - usedPercent
        }

        var resetCountdown: String {
            let now = Date()
            let interval = resetsAt.timeIntervalSince(now)

            guard interval > 0 else { return "已重置" }

            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60

            if hours >= 24 {
                let days = hours / 24
                let remainingHours = hours % 24
                return "\(days)天\(remainingHours)小时后重置"
            } else if hours > 0 {
                return "\(hours)小时\(minutes)分钟后重置"
            } else {
                return "约\(minutes)分钟后重置"
            }
        }

        var timePercent: Double {
            let totalSeconds = Double(windowMinutes * 60)
            let remainingSeconds = resetsAt.timeIntervalSinceNow
            guard totalSeconds > 0 else { return 0 }
            return max(0, min(100, remainingSeconds / totalSeconds * 100))
        }

        var displayData: (remainingPercent: Double, countdown: String, timePercent: Double) {
            let now = Date()
            var currentResetsAt = resetsAt
            var currentRemainingPercent = remainingPercent
            let windowSeconds = Double(windowMinutes * 60)

            if currentResetsAt <= now && windowSeconds > 0 {
                let periods = Int((now.timeIntervalSince(currentResetsAt) / windowSeconds).rounded(.down)) + 1
                currentResetsAt = currentResetsAt.addingTimeInterval(Double(periods) * windowSeconds)
                currentRemainingPercent = 100.0
            }

            let interval = currentResetsAt.timeIntervalSince(now)
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60

            let countdown: String
            if hours >= 24 {
                let days = hours / 24
                let remainingHours = hours % 24
                countdown = "\(days)天\(remainingHours)小时后重置"
            } else if hours > 0 {
                countdown = String(format: "%d小时%02d分后重置", hours, minutes)
            } else {
                countdown = "约\(max(1, minutes))分钟后重置"
            }

            let currentTotalSeconds = Double(windowMinutes * 60)
            let currentRemainingSeconds = currentResetsAt.timeIntervalSince(now)
            let currentTimePercent = max(0, min(100, currentRemainingSeconds / currentTotalSeconds * 100))

            return (currentRemainingPercent, countdown, currentTimePercent)
        }
    }
}
