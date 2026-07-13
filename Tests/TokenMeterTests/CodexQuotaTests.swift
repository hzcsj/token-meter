import XCTest
@testable import TokenMeter

final class CodexQuotaTests: XCTestCase {

    // MARK: - Window Display Label

    func testWindowDisplayLabel5H() {
        let w = makeWindow(windowMinutes: 300)
        XCTAssertEqual(w.displayLabel, "5H")
    }

    func testWindowDisplayLabel7D() {
        let w = makeWindow(windowMinutes: 10080)
        XCTAssertEqual(w.displayLabel, "7D")
    }

    func testWindowDisplayLabelUnknown24H() {
        let w = makeWindow(windowMinutes: 1440)
        XCTAssertEqual(w.displayLabel, "1D")
    }

    func testWindowDisplayLabelUnknown2H() {
        let w = makeWindow(windowMinutes: 120)
        XCTAssertEqual(w.displayLabel, "2H")
    }

    func testWindowDisplayLabelSubHour() {
        let w = makeWindow(windowMinutes: 30)
        XCTAssertEqual(w.displayLabel, "30M")
    }

    func testWindowDisplayLabelNonRoundHour() {
        let w = makeWindow(windowMinutes: 90)
        XCTAssertEqual(w.displayLabel, "90M")
    }

    // MARK: - Remaining Percent

    func testRemainingPercent() {
        let w = makeWindow(usedPercent: 30.0)
        XCTAssertEqual(w.remainingPercent, 70.0, accuracy: 0.01)
    }

    func testRemainingPercentZeroUsed() {
        let w = makeWindow(usedPercent: 0.0)
        XCTAssertEqual(w.remainingPercent, 100.0, accuracy: 0.01)
    }

    func testRemainingPercent100Used() {
        let w = makeWindow(usedPercent: 100.0)
        XCTAssertEqual(w.remainingPercent, 0.0, accuracy: 0.01)
    }

    // MARK: - Dual Window (old format)

    func testDualWindowBothPresent() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(windowMinutes: 300, usedPercent: 20.0),
                makeWindow(windowMinutes: 10080, usedPercent: 16.0),
            ]
        )
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertEqual(quota.windows[0].displayLabel, "5H")
        XCTAssertEqual(quota.windows[1].displayLabel, "7D")
    }

    // MARK: - Single Window (current format: only 7D)

    func testSingleWindow7DOnly() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(sourceSlot: "primary", windowMinutes: 10080, usedPercent: 1.0),
            ]
        )
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].displayLabel, "7D")
        XCTAssertEqual(quota.windows[0].sourceSlot, "primary")
    }

    // MARK: - 5H Restored

    func testBothWindowsRestoredRegardlessOfSlot() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(sourceSlot: "primary", windowMinutes: 300, usedPercent: 10.0),
                makeWindow(sourceSlot: "secondary", windowMinutes: 10080, usedPercent: 5.0),
            ]
        )
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertEqual(quota.windows[0].displayLabel, "5H")
        XCTAssertEqual(quota.windows[1].displayLabel, "7D")
    }

    // MARK: - Swapped Slots

    func testSwappedSlots() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(sourceSlot: "secondary", windowMinutes: 300, usedPercent: 10.0),
                makeWindow(sourceSlot: "primary", windowMinutes: 10080, usedPercent: 5.0),
            ]
        )
        XCTAssertEqual(quota.windows[0].displayLabel, "5H")
        XCTAssertEqual(quota.windows[1].displayLabel, "7D")
    }

    // MARK: - Primary null, Secondary present

    func testPrimaryNullSecondaryPresent() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(sourceSlot: "secondary", windowMinutes: 10080, usedPercent: 3.0),
            ]
        )
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].displayLabel, "7D")
    }

    // MARK: - Only 5H present

    func testOnly5HPresent() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(sourceSlot: "primary", windowMinutes: 300, usedPercent: 50.0),
            ]
        )
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].displayLabel, "5H")
    }

    // MARK: - Both null (empty windows)

    func testBothNull() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: []
        )
        XCTAssertEqual(quota.windows.count, 0)
    }

    func testEmptyTrustedSnapshotSuppressesOlderUntrustedWindows() {
        let trusted = makeSnapshot(windows: [], isTrusted: true)
        let untrusted = makeSnapshot(
            windows: [
                makeWindow(windowMinutes: 300),
                makeWindow(windowMinutes: 10080),
            ],
            isTrusted: false
        )

        XCTAssertNil(resolveCodexQuota(trusted: trusted, untrusted: untrusted))
    }

    func testUntrustedWindowsRemainFallbackWhenTrustedIsMissing() {
        let untrusted = makeSnapshot(
            windows: [makeWindow(windowMinutes: 10080)],
            isTrusted: false
        )

        let quota = resolveCodexQuota(trusted: nil, untrusted: untrusted)
        XCTAssertEqual(quota?.windows.count, 1)
        XCTAssertEqual(quota?.windows.first?.displayLabel, "7D")
    }

    // MARK: - Unknown window period

    func testUnknownWindowPeriodNotDiscarded() {
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                makeWindow(windowMinutes: 300, usedPercent: 10.0),
                makeWindow(windowMinutes: 720, usedPercent: 5.0),
                makeWindow(windowMinutes: 10080, usedPercent: 1.0),
            ]
        )
        XCTAssertEqual(quota.windows.count, 3)
        XCTAssertEqual(quota.windows[0].displayLabel, "5H")
        XCTAssertEqual(quota.windows[1].displayLabel, "12H")
        XCTAssertEqual(quota.windows[2].displayLabel, "7D")
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1784509081)
        let quota = CodexQuota(
            planType: "prolite",
            model: "gpt-5.6-sol",
            windows: [
                CodexQuota.Window(
                    sourceSlot: "primary",
                    usedPercent: 1.0,
                    windowMinutes: 10080,
                    resetsAt: fixedDate
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(quota)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CodexQuota.self, from: data)

        XCTAssertEqual(decoded, quota)
    }

    // MARK: - Display Data: expired window rolls forward

    func testExpiredWindowRollsForward() {
        let pastResets = Date().addingTimeInterval(-3600)
        let w = CodexQuota.Window(
            sourceSlot: "primary",
            usedPercent: 50.0,
            windowMinutes: 300,
            resetsAt: pastResets
        )
        let display = w.displayData
        XCTAssertEqual(display.remainingPercent, 100.0, accuracy: 0.01)
        XCTAssertFalse(display.countdown.contains("已重置"))
    }

    // MARK: - Helpers

    private func makeWindow(
        sourceSlot: String = "primary",
        windowMinutes: Int = 300,
        usedPercent: Double = 0.0,
        resetsAt: Date = Date().addingTimeInterval(3600)
    ) -> CodexQuota.Window {
        CodexQuota.Window(
            sourceSlot: sourceSlot,
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    private func makeSnapshot(
        windows: [CodexQuota.Window],
        isTrusted: Bool
    ) -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(
            windows: windows,
            planType: "prolite",
            model: "gpt-5.6-sol",
            timestamp: Date(timeIntervalSince1970: 1784509081),
            limitId: isTrusted ? "codex" : "codex_bengalfox"
        )
    }
}
