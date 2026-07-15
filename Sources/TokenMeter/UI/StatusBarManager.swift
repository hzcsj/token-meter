import AppKit

final class StatusBarManager: NSObject, NSMenuDelegate {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem!
    private let titleRenderer = TitleRenderer()
    private let menuBuilder = MenuBuilder()
    private let menuRenderGate = MenuRenderGate()
    private let loginItemManager: LoginItemManager
    private lazy var settingsMenuController = SettingsMenuController(
        appName: "TokenMeter",
        loginItemManager: loginItemManager
    )

    private let claudeScanner = ClaudeUsageScanner()
    private let codexScanner = CodexUsageScanner()
    private let openCodeScanner = OpenCodeUsageScanner()

    private let refreshInterval: TimeInterval = 300
    private let refreshDebounce: TimeInterval = 5
    private var timer: Timer?

    private var currentClaudeUsage: UsageSummary?
    private var currentCodexUsage: UsageSummary?
    private var currentOpenCodeUsage: UsageSummary?
    private var currentCodexQuota: CodexQuota?

    private var isRefreshing = false
    private var lastRefreshAt: Date = .distantPast

    private override init() {
        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        loginItemManager = LoginItemManager(
            configuration: LoginItemConfiguration(
                label: "io.github.hzcsj.tokenmeter",
                legacyLabels: ["com.user.tokenmeter"],
                executableURL: executableURL
            )
        )
        super.init()
    }

    func start() {
        do {
            try loginItemManager.reconcileLegacyRegistrations()
        } catch {
            print("LaunchAgent migration failed: \(error.localizedDescription)")
        }
        _ = settingsMenuController

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard statusItem.button != nil else {
            print("Failed to create StatusItem button")
            return
        }

        refreshIfNeeded(force: true)

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshIfNeeded(force: false)
        }
    }

    @objc func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuRenderGate.menuWillOpen()
        refreshIfNeeded(force: false)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menuRenderGate.menuDidClose() {
            renderUI()
        }
    }

    // MARK: - Private

    private func refreshIfNeeded(force: Bool) {
        if !force && Date().timeIntervalSince(lastRefreshAt) < refreshDebounce {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            await refreshAsync()
        }
    }

    private func refreshAsync() async {
        let claudeUsage = claudeScanner.scan()
        let (codexUsage, codexQuota) = codexScanner.scan()
        let openCodeUsage = openCodeScanner.scan()

        currentClaudeUsage = claudeUsage
        currentCodexUsage = codexUsage
        currentOpenCodeUsage = openCodeUsage
        currentCodexQuota = codexQuota

        await MainActor.run {
            lastRefreshAt = Date()
            isRefreshing = false
            renderUI()
        }
    }

    private func renderUI() {
        guard menuRenderGate.requestRender() else { return }
        guard let button = statusItem.button else { return }

        let mergedUsage = menuBuilder.mergeUsage([
            currentClaudeUsage,
            currentCodexUsage,
            currentOpenCodeUsage
        ])

        let image: NSImage
        let todayStr = DateFormatter.yyyyMMdd.string(from: Date())
        if let today = mergedUsage?.byDay.first, today.date == todayStr {
            image = titleRenderer.renderLocalUsage(tokens: today.tokens, cost: today.costCNY)
        } else {
            image = titleRenderer.renderLocalUsage(tokens: 0, cost: 0)
        }

        button.image = image
        button.imagePosition = .imageLeft

        let settingsMenuItem = settingsMenuController.makeParentMenuItem()
        let menu = menuBuilder.build(
            claudeUsage: currentClaudeUsage,
            codexUsage: currentCodexUsage,
            openCodeUsage: currentOpenCodeUsage,
            codexQuota: currentCodexQuota,
            settingsMenuItem: settingsMenuItem
        )

        menu.delegate = self
        statusItem.menu = menu
    }
}
