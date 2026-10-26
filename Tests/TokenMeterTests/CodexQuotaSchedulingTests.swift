import XCTest
@testable import TokenMeter

final class CodexQuotaSchedulingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_039)

    private func attempt(_ policy: inout CodexQuotaRefreshPolicy, after seconds: TimeInterval,
                         trigger: CodexQuotaRefreshTrigger = .periodic, active: Bool = true,
                         noSubscription: Bool = false) -> Bool {
        policy.beginAttempt(trigger: trigger, isActive: active, noSubscription: noSubscription,
                            now: start.addingTimeInterval(seconds))
    }

    func testActiveAndIdleIntervalsAndActivityTransitions() {
        var policy = CodexQuotaRefreshPolicy()
        XCTAssertTrue(attempt(&policy, after: 0, trigger: .startup))
        XCTAssertFalse(attempt(&policy, after: 299))
        XCTAssertTrue(attempt(&policy, after: 300))
        XCTAssertFalse(attempt(&policy, after: 600, active: false))
        XCTAssertFalse(attempt(&policy, after: 2099, active: false))
        XCTAssertTrue(attempt(&policy, after: 2100, active: false))
        XCTAssertTrue(attempt(&policy, after: 2400))
        XCTAssertEqual(policy.lastAttempt, start.addingTimeInterval(2400))
    }

    func testMenuDebounceIsRollingAndSharedWithAllTriggers() {
        var policy = CodexQuotaRefreshPolicy()
        XCTAssertTrue(attempt(&policy, after: 0, trigger: .startup))
        // The next second is a new wall-clock minute, but not a new request slot.
        for second: TimeInterval in [1, 30, 59.999] {
            for trigger: CodexQuotaRefreshTrigger in [.menu, .startup, .wake, .periodic] {
                XCTAssertFalse(attempt(&policy, after: second, trigger: trigger))
            }
        }
        XCTAssertTrue(attempt(&policy, after: 60, trigger: .menu, active: false))
        XCTAssertFalse(attempt(&policy, after: 119, trigger: .menu))
        XCTAssertTrue(attempt(&policy, after: 120, trigger: .menu))
        XCTAssertFalse(attempt(&policy, after: 300))
        XCTAssertTrue(attempt(&policy, after: 420))
    }

    func testWakeRespectsCadenceAndLongSleepCanRefreshImmediately() {
        var policy = CodexQuotaRefreshPolicy()
        XCTAssertTrue(attempt(&policy, after: 0))
        XCTAssertFalse(attempt(&policy, after: 60, trigger: .wake))
        XCTAssertTrue(attempt(&policy, after: 300, trigger: .wake))
        XCTAssertFalse(attempt(&policy, after: 600, trigger: .wake, active: false))
        XCTAssertTrue(attempt(&policy, after: 7200, trigger: .wake, active: false))
        XCTAssertFalse(attempt(&policy, after: 7200, trigger: .periodic, active: false))
    }

    func testSignedOutUsesIdleCadenceEvenWithActiveLocalUsage() {
        var policy = CodexQuotaRefreshPolicy()
        XCTAssertTrue(attempt(&policy, after: 0, noSubscription: true))
        XCTAssertFalse(attempt(&policy, after: 300, noSubscription: true))
        XCTAssertFalse(attempt(&policy, after: 1799, noSubscription: true))
        XCTAssertTrue(attempt(&policy, after: 1800, noSubscription: true))
        XCTAssertTrue(attempt(&policy, after: 1860, trigger: .menu, noSubscription: true))
    }

    func testMinuteTicksDoNotBecomeMinuteRequests() {
        for (active, expected) in [(true, 13), (false, 3)] {
            var policy = CodexQuotaRefreshPolicy()
            let count = stride(from: 0, through: 3600, by: 60).filter {
                attempt(&policy, after: Double($0), active: active)
            }.count
            XCTAssertEqual(count, expected) // Includes the initial request at t=0.
        }
    }

    func testClockMovingBackwardCannotCauseARequestBurst() {
        var policy = CodexQuotaRefreshPolicy()
        XCTAssertTrue(attempt(&policy, after: 0))
        XCTAssertFalse(attempt(&policy, after: -60, trigger: .menu))
        XCTAssertFalse(attempt(&policy, after: 59, trigger: .menu))
        XCTAssertTrue(attempt(&policy, after: 60, trigger: .menu))
    }

    func testFailedReadsAreThrottledAndMenuRemainsAvailable() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CodexQuotaService(cacheURL: file)
        let reader = CountingReader()
        _ = await service.refresh(trigger: .startup, isActive: true, now: start, read: { reader.read() })
        for second in [60, 120, 299] {
            _ = await service.refresh(trigger: .periodic, isActive: true,
                now: start.addingTimeInterval(Double(second)), read: { reader.read() })
        }
        XCTAssertEqual(reader.count, 1)
        _ = await service.refresh(trigger: .menu, now: start.addingTimeInterval(299), read: { reader.read() })
        _ = await service.refresh(trigger: .periodic, isActive: true,
            now: start.addingTimeInterval(300), read: { reader.read() })
        XCTAssertEqual(reader.count, 2)
        _ = await service.refresh(trigger: .periodic, isActive: true,
            now: start.addingTimeInterval(599), read: { reader.read() })
        XCTAssertEqual(reader.count, 3)
    }

    func testServicePropagatesNoSubscriptionToScheduling() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CodexQuotaService(cacheURL: file)
        _ = await service.refresh(trigger: .startup, now: start, read: { .noSubscription })
        let result = await service.refresh(trigger: .periodic, isActive: true,
            now: start.addingTimeInterval(300), read: {
                XCTFail("Local API-key usage must not accelerate account checks")
                return .unavailable
            })
        guard case .noSubscription = result else { return XCTFail("Quota must stay hidden") }
        let reader = CountingReader()
        _ = await service.refresh(trigger: .periodic, isActive: true,
            now: start.addingTimeInterval(1800), read: { reader.read() })
        XCTAssertEqual(reader.count, 1)
    }

    func testInFlightReadIsNotDuplicatedOrAllowedToMoveTheDeadline() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CodexQuotaService(cacheURL: file)
        let entered = expectation(description: "read started")
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            await service.refresh(trigger: .startup, now: start, read: {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return .unavailable
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        _ = await service.refresh(trigger: .menu, now: start.addingTimeInterval(60), read: {
            XCTFail("A request is already running")
            return .unavailable
        })
        release.signal()
        _ = await first.value
        let reader = CountingReader()
        _ = await service.refresh(trigger: .menu, now: start.addingTimeInterval(60), read: { reader.read() })
        XCTAssertEqual(reader.count, 1)
    }
}

private final class CountingReader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    func read() -> CodexQuotaReadResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return .unavailable
    }
}
