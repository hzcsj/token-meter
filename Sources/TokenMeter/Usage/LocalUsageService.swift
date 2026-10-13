import Foundation

struct LocalUsageSnapshot: Codable, Equatable {
    let claude: UsageSummary?
    let codex: UsageSummary?
    let openCode: UsageSummary?
    let codexQuota: CodexQuota?
}

struct UsageSnapshotStore {
    private let fileURL: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("token-meter", isDirectory: true),
         pricingKey: String = PricingEngine.shared.cacheKey) {
        fileURL = directory.appendingPathComponent("usage_snapshot_v1_\(pricingKey).json")
    }

    func load() -> LocalUsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LocalUsageSnapshot.self, from: data)
    }

    func save(_ snapshot: LocalUsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// Initialize and scan the potentially large file caches off the UI actor.
// Each mutable incremental cache belongs to this actor and scans never overlap.
private actor LocalUsageScanner {
    private lazy var claude = ClaudeUsageScanner()
    private lazy var codex = CodexUsageScanner()
    private lazy var openCode = OpenCodeUsageScanner()

    func scan() -> LocalUsageSnapshot {
        let claudeUsage = claude.scan()
        let (codexUsage, quota) = codex.scan()
        return LocalUsageSnapshot(claude: claudeUsage, codex: codexUsage,
                                  openCode: openCode.scan(), codexQuota: quota)
    }
}

@MainActor
final class LocalUsageService {
    private let store: UsageSnapshotStore
    private let scan: () async -> LocalUsageSnapshot
    private var lastRefreshAt: Date = .distantPast
    private(set) var snapshot: LocalUsageSnapshot?
    private(set) var isRefreshing = false

    var isLoading: Bool { snapshot == nil }

    init(store: UsageSnapshotStore = UsageSnapshotStore(),
         scan: (() async -> LocalUsageSnapshot)? = nil) {
        self.store = store
        let scanner = LocalUsageScanner()
        self.scan = scan ?? { await scanner.scan() }
        snapshot = store.load()
    }

    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard !isRefreshing,
              force || Date().timeIntervalSince(lastRefreshAt) >= 5 else { return false }
        isRefreshing = true
        let updated = await scan()
        // Keep the previous complete snapshot visible until all sources finish.
        snapshot = updated
        store.save(updated)
        lastRefreshAt = Date()
        isRefreshing = false
        return true
    }
}
