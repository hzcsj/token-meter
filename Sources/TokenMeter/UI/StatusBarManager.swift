import AppKit

final class StatusBarManager: NSObject {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem!
    private let titleRenderer = TitleRenderer()
    private let menuBuilder = MenuBuilder()

    private let claudeScanner = ClaudeUsageScanner()
    private let codexScanner = CodexUsageScanner()

    private let refreshInterval: TimeInterval = 300
    private var timer: Timer?

    private var currentClaudeUsage: UsageSummary?
    private var currentCodexUsage: UsageSummary?
    private var currentCodexQuota: CodexQuota?

    private override init() {
        super.init()
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard statusItem.button != nil else {
            print("Failed to create StatusItem button")
            return
        }

        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        Task {
            await refreshAsync()
        }
    }

    @objc func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func refreshAsync() async {
        let claudeUsage = claudeScanner.scan()
        let (codexUsage, codexQuota) = codexScanner.scan()

        currentClaudeUsage = claudeUsage
        currentCodexUsage = codexUsage
        currentCodexQuota = codexQuota

        await MainActor.run {
            renderUI()
        }
    }

    private func renderUI() {
        guard let button = statusItem.button else { return }

        let mergedUsage = menuBuilder.mergeUsage(claude: currentClaudeUsage, codex: currentCodexUsage)

        let image: NSImage
        let todayStr = DateFormatter.yyyyMMdd.string(from: Date())
        if let today = mergedUsage?.byDay.first, today.date == todayStr {
            image = titleRenderer.renderLocalUsage(tokens: today.tokens, cost: today.costCNY)
        } else {
            image = titleRenderer.renderLocalUsage(tokens: 0, cost: 0)
        }

        button.image = image
        button.imagePosition = .imageLeft

        let menu = menuBuilder.build(
            claudeUsage: currentClaudeUsage,
            codexUsage: currentCodexUsage,
            codexQuota: currentCodexQuota
        )

        statusItem.menu = menu
    }
}
