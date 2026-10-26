import AppKit

@MainActor
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

    private let localUsageService = LocalUsageService()
    private let codexQuotaService = CodexQuotaService()
    private let codexActivityMonitor = CodexActivityMonitor()
    private var liveCodexQuota: CodexQuotaReadResult = .unavailable

    private let refreshInterval: TimeInterval = 300
    private var timer: Timer?
    private var quotaTimer: Timer?

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

        renderUI()
        refreshIfNeeded(force: true)
        refreshQuota(trigger: .startup)

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded(force: false) }
        }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // This tick only inspects local activity and updates the countdown.
            // The shared policy permits a network read every 5 or 30 minutes.
            Task { @MainActor in self?.refreshQuota(trigger: .periodic) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshQuotaAfterWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuRenderGate.menuWillOpen()
        refreshIfNeeded(force: false)
        refreshQuota(trigger: .menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menuRenderGate.menuDidClose() {
            renderUI()
        }
    }

    // MARK: - Private

    @objc private func refreshQuotaAfterWake() {
        refreshQuota(trigger: .wake)
    }

    private func refreshQuota(trigger: CodexQuotaRefreshTrigger) {
        Task {
            let active = await codexActivityMonitor.isActive()
            let result = await codexQuotaService.refresh(trigger: trigger, isActive: active)
            await MainActor.run {
                liveCodexQuota = result
                renderUI()
            }
        }
    }

    private func refreshIfNeeded(force: Bool) {
        Task {
            if await localUsageService.refresh(force: force) {
                renderUI()
            }
        }
    }

    private func renderUI() {
        guard menuRenderGate.requestRender() else { return }
        guard let button = statusItem.button else { return }

        let snapshot = localUsageService.snapshot
        let mergedUsage = menuBuilder.mergeUsage([snapshot?.claude, snapshot?.codex, snapshot?.openCode])

        let image: NSImage
        let todayStr = DateFormatter.yyyyMMdd.string(from: Date())
        if localUsageService.isLoading {
            image = titleRenderer.renderLoading()
        } else if let today = mergedUsage?.byDay.first, today.date == todayStr {
            image = titleRenderer.renderLocalUsage(tokens: today.tokens, cost: today.costCNY)
        } else {
            image = titleRenderer.renderLocalUsage(tokens: 0, cost: 0)
        }

        button.image = image
        button.imagePosition = .imageLeft

        let settingsMenuItem = settingsMenuController.makeParentMenuItem()
        let menu = menuBuilder.build(
            claudeUsage: snapshot?.claude,
            codexUsage: snapshot?.codex,
            openCodeUsage: snapshot?.openCode,
            codexQuota: displayedCodexQuota(live: liveCodexQuota, local: snapshot?.codexQuota),
            isUsageLoading: localUsageService.isLoading,
            settingsMenuItem: settingsMenuItem
        )

        menu.delegate = self
        statusItem.menu = menu
    }
}
