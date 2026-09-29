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
                             ["type": "chatgpt", "planType": "free"],
                             ["type": "chatgpt", "planType": "go"]] {
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
        XCTAssertNil(displayedCodexQuota(live: .unavailable, local: local))
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
        guard case .cached(let saved) = cached else { return XCTFail("Keep last known main bucket as cached, not live") }
        XCTAssertEqual(saved.windows, q.windows)
        let reloaded = CodexQuotaService(cacheURL: file)
        guard case .cached = await reloaded.refresh(now: now, read: { .unavailable }) else {
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

    func testDesktopLayoutsWorkWithoutShellPATHAndAreRediscovered() {
        let directories = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/test/Applications")]
        let layouts = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Users/test/Applications/Codex.app/Contents/Resources/codex",
        ]
        for installed in layouts {
            let result = CodexQuotaClient.executableURL(applicationDirectories: directories,
                path: "/usr/bin:/bin:/usr/sbin:/sbin", isExecutable: { $0 == installed }, bundleExecutable: { _ in nil })
            XCTAssertEqual(result?.path, installed)
        }
        XCTAssertNil(CodexQuotaClient.executableURL(applicationDirectories: directories,
            path: "relative/bin", isExecutable: { _ in false }, bundleExecutable: { _ in nil }))
    }

    func testBundleMetadataAndStandaloneCLIFallback() {
        let custom = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/renamed")
        XCTAssertEqual(CodexQuotaClient.executableURL(applicationDirectories: [URL(fileURLWithPath: "/Applications")],
            path: "", isExecutable: { $0 == custom.path }, bundleExecutable: { _ in custom }), custom)
        let cli = "/custom/bin/codex"
        XCTAssertEqual(CodexQuotaClient.executableURL(applicationDirectories: [], path: "relative:/custom/bin",
            isExecutable: { $0 == cli }, bundleExecutable: { _ in nil })?.path, cli)
    }

    func testNewLocalObservationReplacesFailedLiveCacheButNotSuccessfulRead() throws {
        let old = try XCTUnwrap(parse(["rateLimits": bucket(primary: window(10080, used: 4))]))
        let newer = CodexQuotaSnapshot(windows: [CodexQuota.Window(sourceSlot: "primary", usedPercent: 13,
            windowMinutes: 10080, resetsAt: old.windows[0].resetsAt)], planType: "pro", model: "gpt-6-astra",
            timestamp: now.addingTimeInterval(60), limitId: "codex")
        let local = try XCTUnwrap(resolveCodexQuota(trusted: newer, untrusted: nil))
        XCTAssertEqual(local.observedAt, newer.timestamp)
        XCTAssertEqual(displayedCodexQuota(live: .cached(old), local: local)?.windows[0].remainingPercent, 87)
        XCTAssertEqual(displayedCodexQuota(live: .quota(old), local: local)?.windows[0].remainingPercent, 96)
        XCTAssertNil(displayedCodexQuota(live: .noSubscription, local: local))
        XCTAssertNil(displayedCodexQuota(live: .unavailable, local: local))
    }

    func testBankedResetReplacesEntireSnapshotWithoutMixingWindows() throws {
        let old = try XCTUnwrap(parse(["rateLimits": bucket(primary: window(300, used: 50), secondary: window(10080, used: 100))]))
        let reset = now.addingTimeInterval(7 * 86400)
        let new = CodexQuotaSnapshot(windows: [.init(sourceSlot: "primary", usedPercent: 2,
            windowMinutes: 10080, resetsAt: reset)], planType: "pro", model: "gpt-6-sol",
            timestamp: now.addingTimeInterval(120), limitId: "codex")
        let local = resolveCodexQuota(trusted: new, untrusted: nil)
        let displayed = try XCTUnwrap(displayedCodexQuota(live: .cached(old), local: local))
        XCTAssertEqual(displayed.windows.map(\.windowMinutes), [10080])
        XCTAssertEqual(displayed.windows[0].resetsAt, reset)
        XCTAssertEqual(displayed.windows[0].remainingPercent, 98)
    }

    func testStaleAuxiliaryUnknownTimeAndDifferentPlanCannotOverrideCache() throws {
        let old = try XCTUnwrap(parse(["rateLimits": bucket(primary: window(10080, used: 4))]))
        for (plan, id, date): (String, String?, Date?) in [
            ("pro", "codex_bengalfox", now.addingTimeInterval(60)),
            ("plus", "codex", now.addingTimeInterval(60)),
            ("pro", "codex", now.addingTimeInterval(-60)),
            ("pro", "codex", nil),
            ("pro", "codex", Date().addingTimeInterval(3600)),
        ] {
            let local = CodexQuota(planType: plan, model: "gpt-6-astra", windows: [
                .init(sourceSlot: "primary", usedPercent: 13, windowMinutes: 10080, resetsAt: old.windows[0].resetsAt)
            ], observedAt: date, limitId: id)
            XCTAssertEqual(displayedCodexQuota(live: .cached(old), local: local)?.windows[0].remainingPercent, 96)
        }
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
