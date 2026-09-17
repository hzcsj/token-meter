import XCTest
@testable import TokenMeter

final class CodexQuotaClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func window(_ minutes: Int = 10080, used: Double = 52) -> [String: Any] {
        ["usedPercent": used, "windowDurationMins": minutes, "resetsAt": now.timeIntervalSince1970 + 86400]
    }

    private func bucket(primary: Any? = nil, secondary: Any = NSNull()) -> [String: Any] {
        ["limitId": "codex", "planType": NSNull(), "primary": primary ?? window(), "secondary": secondary]
    }

    private func parse(_ result: [String: Any]) -> CodexQuotaSnapshot? {
        CodexQuotaExchange.parseQuota(result, planType: "pro", now: now)
    }

    func testMainBucketWinsOverAuxiliaryLegacyView() throws {
        let q = try XCTUnwrap(parse([
            "rateLimits": ["limitId": "codex_bengalfox", "primary": window(300, used: 0)],
            "rateLimitsByLimitId": ["codex": bucket(), "codex_bengalfox": ["primary": window(10080, used: 0)]],
        ]))
        XCTAssertEqual(q.windows.count, 1)
        XCTAssertEqual(q.windows[0].remainingPercent, 48)
        XCTAssertEqual(q.windows[0].displayLabel, "7D")
        XCTAssertEqual(q.planType, "pro")
        XCTAssertTrue(q.isTrusted)
    }

    func testNeverUsesAuxiliaryBucketWhenMainMissing() {
        XCTAssertNil(parse(["rateLimits": ["limitId": "codex_bengalfox", "primary": window()],
                            "rateLimitsByLimitId": ["codex_bengalfox": bucket()]]))
        XCTAssertNil(parse(["rateLimits": ["primary": window()]]))
    }

    func testLegacyMainAndSwappedWindowSlots() throws {
        let q = try XCTUnwrap(parse(["rateLimits": bucket(secondary: window(300, used: 10))]))
        XCTAssertEqual(q.windows.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(q.windows.map(\.sourceSlot), ["secondary", "primary"])
        let secondaryOnly = try XCTUnwrap(parse(["rateLimits": bucket(primary: NSNull(), secondary: window())]))
        XCTAssertEqual(secondaryOnly.windows.count, 1)
    }

    func testRejectsMissingMalformedAndExpiredWindowsInsteadOfInventing100Percent() {
        for value: Any in [NSNull(), [:], ["usedPercent": 10], window(0), window(10080, used: -1),
                           window(10080, used: 101), ["usedPercent": 1, "windowDurationMins": 300, "resetsAt": 1]] {
            XCTAssertNil(parse(["rateLimits": bucket(primary: value)]))
        }
    }

    func testMapKeyCanSupplyMissingLimitID() {
        var main = bucket()
        main.removeValue(forKey: "limitId")
        XCTAssertNotNil(parse(["rateLimitsByLimitId": ["codex": main]]))
        main["limitId"] = "codex_bengalfox"
        XCTAssertNil(parse(["rateLimitsByLimitId": ["codex": main]]))
    }

    private func initializedExchange() -> CodexQuotaExchange {
        var exchange = CodexQuotaExchange()
        XCTAssertEqual(exchange.initialRequest["method"] as? String, "initialize")
        let step = exchange.receive(["id": 1, "result": [:]])
        XCTAssertEqual(step.requests.compactMap { $0["method"] as? String }, ["initialized", "account/read"])
        return exchange
    }

    func testNoLoginAPIKeyAndFreeAccountsNeverRequestQuotaOrLogin() {
        for account: Any in [NSNull(), ["type": "apiKey"], ["type": "amazonBedrock"],
                             ["type": "chatgpt", "planType": "free"]] {
            var exchange = initializedExchange()
            let step = exchange.receive(["id": 2, "result": ["account": account]])
            XCTAssertTrue(step.requests.isEmpty)
            guard case .noSubscription? = step.result else { return XCTFail("Must hide quotas") }
        }
    }

    func testSubscribedHandshakeAndNotifications() {
        var exchange = initializedExchange()
        XCTAssertNil(exchange.receive(["method": "account/updated", "params": [:]]).result)
        XCTAssertNil(exchange.receive(["id": 77, "result": [:]]).result)
        let step = exchange.receive(["id": 2, "result": ["account": ["type": "chatgpt", "planType": "pro"]]])
        XCTAssertEqual(step.requests.first?["method"] as? String, "account/rateLimits/read")
        let refresh = exchange.receive(["id": 98, "method": "account/chatgptAuthTokens/refresh"])
        XCTAssertNotNil(refresh.requests.first?["error"])
        XCTAssertNil(refresh.requests.first?["result"])
        guard case .unavailable? = exchange.receive(["id": 3, "error": ["code": -32000]]).result
        else { return XCTFail("Errors must not invent a quota") }
    }

    func testNoSubscriptionSuppressesOldLocalQuota() throws {
        let q = try XCTUnwrap(parse(["rateLimits": bucket()]))
        let local = resolveCodexQuota(trusted: q, untrusted: nil)
        XCTAssertNil(displayedCodexQuota(live: .noSubscription, local: local))
        XCTAssertEqual(displayedCodexQuota(live: .unavailable, local: local), local)
        XCTAssertNil(displayedCodexQuota(live: .unavailable, local: nil))
        XCTAssertEqual(displayedCodexQuota(live: .quota(q), local: local)?.windows.first?.remainingPercent, 48)
    }

    func testCacheSurvivesNetworkFailureButIsClearedWhenLoggedOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quota.json")
        let service = CodexQuotaService(cacheURL: file)
        let q = try XCTUnwrap(parse(["rateLimits": bucket()]))
        _ = await service.refresh(now: now, read: { .quota(q) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let cached = await service.refresh(now: now.addingTimeInterval(60), read: { .unavailable })
        guard case .quota(let saved) = cached else { return XCTFail("Keep last known main bucket") }
        XCTAssertEqual(saved.windows, q.windows)
        let reloaded = CodexQuotaService(cacheURL: file)
        guard case .quota = await reloaded.refresh(now: now, read: { .unavailable }) else {
            return XCTFail("Cache must survive restart")
        }
        guard case .noSubscription = await service.refresh(now: now.addingTimeInterval(120), read: { .noSubscription }) else {
            return XCTFail("Signed out must hide cached quota")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        guard case .noSubscription = await service.refresh(now: now.addingTimeInterval(180), read: { .unavailable }) else {
            return XCTFail("Offline must not restore a logged-out quota")
        }
        guard case .quota = await service.refresh(now: now.addingTimeInterval(240), read: { .quota(q) }) else {
            return XCTFail("Normal login must resume quota reads")
        }
    }

    func testDebouncesMenuRefreshes() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = CodexQuotaService(cacheURL: file)
        _ = await service.refresh(now: now, read: { .noSubscription })
        _ = await service.refresh(now: now.addingTimeInterval(5), read: {
            XCTFail("Must not start a second query within 30 seconds")
            return .unavailable
        })
    }

    func testTransportCompletesHandshakeWithoutAnyLoginRequests() {
        let script = #"""
        IFS= read -r line
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        printf '%s\n' '{"id":2,"result":{"account":null}}'
        """#
        guard case .noSubscription = CodexQuotaClient.read(executable: URL(fileURLWithPath: "/bin/sh"),
                                                          arguments: ["-c", script], timeout: 2) else {
            return XCTFail("Expected unauthenticated result from stdio")
        }
    }

    func testTransportTimeoutAndMissingExecutableFailSilently() {
        let start = Date()
        guard case .unavailable = CodexQuotaClient.read(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                       arguments: ["5"], timeout: 0.1) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        guard case .unavailable = CodexQuotaClient.read(executable: URL(fileURLWithPath: "/nonexistent/token-meter-test"))
        else { return XCTFail() }
        guard case .unavailable = CodexQuotaClient.read(executable: nil) else { return XCTFail() }
    }

    func testLiveReadWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["TOKEN_METER_LIVE_QUOTA_TEST"] == "1" else {
            throw XCTSkip("Live account access is opt-in")
        }
        guard case .quota(let q) = CodexQuotaClient.read() else { return XCTFail("Expected existing subscription login") }
        XCTAssertTrue(q.isTrusted)
        XCTAssertFalse(q.windows.isEmpty)
        print("Live main quota: " + q.windows.map { "\($0.displayLabel) \(Int($0.remainingPercent))% remaining" }.joined(separator: ", "))
    }
}
