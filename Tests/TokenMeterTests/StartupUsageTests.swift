import AppKit
import XCTest
@testable import TokenMeter

final class StartupUsageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func summary(_ tokens: Int) -> UsageSummary {
        let day = DailyUsage(date: DateFormatter.yyyyMMdd.string(from: Date()), tokens: tokens,
                             costCNY: Double(tokens) / 100, messageCount: 1)
        return UsageSummary(byDay: [day], weekTotal: day, monthTotal: day, allTimeTotal: day)
    }

    private func snapshot(_ tokens: Int = 100) -> LocalUsageSnapshot {
        LocalUsageSnapshot(claude: summary(tokens), codex: summary(tokens * 2),
                           openCode: summary(tokens * 3), codexQuota: CodexQuota(
                            planType: "pro", model: "gpt-6.1-sol",
                            windows: [CodexQuota.Window(sourceSlot: "secondary", usedPercent: 10,
                                windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86400))],
                            observedAt: Date(), limitId: "codex"))
    }

    private func quota() -> CodexQuotaReadResult {
        .quota(CodexQuotaSnapshot(windows: [CodexQuota.Window(sourceSlot: "secondary",
            usedPercent: 12, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86400))],
            planType: "pro", model: "", timestamp: Date(), limitId: "codex"))
    }

    private func texts(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { $0.view?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? [] }
    }

    @MainActor
    func testWarmRestartKeepsCompleteUsageWhileQuotaAndSlowScanRefresh() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageSnapshotStore(directory: directory, pricingKey: "current")
        let previous = snapshot()
        store.save(previous)
        let started = expectation(description: "scan started")
        var continuation: CheckedContinuation<LocalUsageSnapshot, Never>?
        var calls = 0
        let service = LocalUsageService(store: store, scan: {
            calls += 1
            return await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        })
        XCTAssertEqual(service.snapshot, previous)
        XCTAssertFalse(service.isLoading)
        let task = Task { await service.refresh(force: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(service.isRefreshing)
        XCTAssertEqual(service.snapshot, previous)
        let overlapping = await service.refresh(force: true)
        XCTAssertFalse(overlapping)
        XCTAssertEqual(calls, 1)

        // Reproduce the original race: live quota arrives before local scanning.
        let live = displayedCodexQuota(live: quota(), local: service.snapshot?.codexQuota)
        XCTAssertEqual(live?.model, "gpt-6.1-sol")
        XCTAssertEqual(live?.windows.first?.remainingPercent, 88)
        let menu = MenuBuilder().build(claudeUsage: service.snapshot?.claude,
            codexUsage: service.snapshot?.codex, openCodeUsage: service.snapshot?.openCode,
            codexQuota: live, isUsageLoading: service.isLoading)
        XCTAssertTrue(texts(menu).contains("历史累计"))
        XCTAssertFalse(texts(menu).contains("正在读取本地用量…"))
        XCTAssertEqual(MenuBuilder().mergeUsage([service.snapshot?.claude, service.snapshot?.codex,
                                               service.snapshot?.openCode])?.allTimeTotal.tokens, 600)

        let updated = snapshot(200)
        continuation?.resume(returning: updated)
        let refreshed = await task.value
        XCTAssertTrue(refreshed)
        XCTAssertFalse(service.isRefreshing)
        XCTAssertEqual(service.snapshot, updated)
        XCTAssertEqual(store.load(), updated)
        let debounced = await service.refresh()
        XCTAssertFalse(debounced)
        XCTAssertEqual(calls, 1)

        let restarted = LocalUsageService(store: store, scan: { XCTFail("No scan before refresh"); return updated })
        XCTAssertEqual(restarted.snapshot, updated)
        XCTAssertFalse(restarted.isLoading)
        // Restoring local usage must never establish a subscription login.
        XCTAssertNil(displayedCodexQuota(live: .noSubscription, local: restarted.snapshot?.codexQuota))
        XCTAssertNil(displayedCodexQuota(live: .unavailable, local: restarted.snapshot?.codexQuota))
    }

    @MainActor
    func testColdStartupShowsLoadingUntilScanCompletesEvenWhenQuotaArrivesFirst() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "cold scan started")
        var continuation: CheckedContinuation<LocalUsageSnapshot, Never>?
        let service = LocalUsageService(store: UsageSnapshotStore(directory: directory, pricingKey: "new"), scan: {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        })
        let task = Task { await service.refresh(force: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(service.isLoading)
        for live in [quota(), .noSubscription] {
            let menu = MenuBuilder().build(claudeUsage: nil, codexUsage: nil, openCodeUsage: nil,
                codexQuota: displayedCodexQuota(live: live, local: nil), isUsageLoading: service.isLoading)
            XCTAssertTrue(texts(menu).contains("📈 本地用量统计"))
            XCTAssertTrue(texts(menu).contains("正在读取本地用量…"))
            XCTAssertFalse(texts(menu).contains("暂无本地用量"))
        }
        continuation?.resume(returning: snapshot())
        _ = await task.value
        XCTAssertFalse(service.isLoading)
        let menu = MenuBuilder().build(claudeUsage: service.snapshot?.claude,
            codexUsage: service.snapshot?.codex, openCodeUsage: service.snapshot?.openCode,
            codexQuota: nil, isUsageLoading: service.isLoading)
        XCTAssertTrue(texts(menu).contains("历史累计"))
        XCTAssertFalse(texts(menu).contains("正在读取本地用量…"))
    }

    @MainActor
    func testEmptyCompletedScanIsNotPerpetuallyLoading() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageSnapshotStore(directory: directory, pricingKey: "empty")
        let empty = LocalUsageSnapshot(claude: nil, codex: nil, openCode: nil, codexQuota: nil)
        let service = LocalUsageService(store: store, scan: { empty })
        _ = await service.refresh(force: true)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(store.load(), empty)
        let menu = MenuBuilder().build(claudeUsage: nil, codexUsage: nil, openCodeUsage: nil,
                                      codexQuota: nil, isUsageLoading: service.isLoading)
        XCTAssertTrue(texts(menu).contains("暂无本地用量"))
        XCTAssertFalse(texts(menu).contains("正在读取本地用量…"))
        XCTAssertTrue(menu.items.compactMap { $0.view as? MenuQuotaRowView }.isEmpty)
    }

    func testSnapshotRejectsDifferentPricingOrCorruptDataAndCanRecover() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = UsageSnapshotStore(directory: directory, pricingKey: "old")
        let current = UsageSnapshotStore(directory: directory, pricingKey: "current")
        let saved = snapshot()
        old.save(saved)
        XCTAssertNil(current.load())
        let file = directory.appendingPathComponent("usage_snapshot_v1_current.json")
        try Data("{truncated".utf8).write(to: file)
        XCTAssertNil(current.load())
        current.save(saved)
        XCTAssertEqual(current.load(), saved)
        let replacement = snapshot(200)
        current.save(replacement)
        XCTAssertEqual(current.load(), replacement)
        XCTAssertEqual(old.load(), saved)
    }

    func testQuotaColumnsNeverTouchOrOverlapWithoutUsageWidths() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for width: CGFloat in [0, 200, 650] {
            for (left, right) in [("7D 额度剩余： 90%", "5天14小时后重置  (79.8%)"),
                                  ("5H 额度剩余：100%", "4小时59分后重置  (99.8%)")] {
                let row = MenuQuotaRowView(left: left, right: right, font: font,
                                          color: .labelColor, contentWidth: width)
                let fields = row.subviews.compactMap { $0 as? NSTextField }
                XCTAssertEqual(fields.count, 2)
                let lhs = try XCTUnwrap(fields.first)
                let rhs = try XCTUnwrap(fields.last)
                XCTAssertGreaterThanOrEqual(rhs.frame.minX - lhs.frame.maxX, textWidth("  ", font: font))
                XCTAssertLessThanOrEqual(rhs.frame.maxX, row.bounds.maxX - MenuLayout.rightPad)
            }
        }
    }
}
