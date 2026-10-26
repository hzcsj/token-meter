import Foundation

enum CodexQuotaRefreshTrigger {
    case startup, periodic, wake, menu
}

struct CodexQuotaRefreshPolicy {
    static let minimumInterval: TimeInterval = 60
    static let activeInterval: TimeInterval = 5 * 60
    static let idleInterval: TimeInterval = 30 * 60

    private(set) var lastAttempt: Date?

    mutating func beginAttempt(trigger: CodexQuotaRefreshTrigger, isActive: Bool,
                               noSubscription: Bool, now: Date) -> Bool {
        if let lastAttempt {
            let elapsed = now.timeIntervalSince(lastAttempt)
            // One rolling 60-second gate for every trigger, including failed reads.
            guard elapsed >= Self.minimumInterval else { return false }
            if trigger == .periodic || trigger == .wake {
                let interval = isActive && !noSubscription ? Self.activeInterval : Self.idleInterval
                guard elapsed >= interval else { return false }
            }
        }
        lastAttempt = now
        return true
    }
}
