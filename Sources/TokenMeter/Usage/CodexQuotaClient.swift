import Foundation
import Darwin
import OSLog

enum CodexQuotaReadResult {
    case quota(CodexQuotaSnapshot)
    case cached(CodexQuotaSnapshot)
    case noSubscription
    case unavailable
}

/// Only account RPCs are used. Authentication and refresh remain owned by Codex;
/// TokenMeter never opens credential files or starts a login flow.
struct CodexQuotaClient {
    private static let logger = Logger(subsystem: "io.github.hzcsj.tokenmeter", category: "CodexQuota")

    // Resolve again on every attempt: the desktop app can replace its bundled CLI
    // while TokenMeter stays running, and launchd has a minimal PATH.
    static func executableURL(
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        bundleExecutable: (URL) -> URL? = { Bundle(url: $0)?.executableURL }
    ) -> URL? {
        var candidates: [String] = []
        for directory in applicationDirectories {
            for name in ["ChatGPT.app", "Codex.app"] {
                let resources = directory.appendingPathComponent("\(name)/Contents/Resources")
                let cliBundle = resources.appendingPathComponent("codex-cli/CodexCLI.app")
                if let executable = bundleExecutable(cliBundle) { candidates.append(executable.path) }
                candidates.append(cliBundle.appendingPathComponent("Contents/MacOS/codex").path)
                candidates.append(resources.appendingPathComponent("codex").path)
            }
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] + path
            .split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        return candidates.first(where: isExecutable)
            .map { URL(fileURLWithPath: $0) }
    }

    private static func unavailable(_ reason: String) -> CodexQuotaReadResult {
        // Only fixed diagnostic categories, never RPC payloads or credentials.
        logger.notice("Quota refresh unavailable: \(reason, privacy: .public)")
        return .unavailable
    }

    static func read(
        executable: URL? = executableURL(),
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        timeout: TimeInterval = 20
    ) -> CodexQuotaReadResult {
        guard let executable else { return unavailable("executable_missing") }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        // Do not load the repository's project-specific configuration.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let end = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
            try? output.fileHandleForReading.close()
        }
        do {
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            var exchange = CodexQuotaExchange()
            func send(_ message: [String: Any]) throws {
                var bytes = try JSONSerialization.data(withJSONObject: message)
                bytes.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: bytes)
            }
            try send(exchange.initialRequest)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var buffer = Data()
            var bytesRead = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                        events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; return unavailable("transport_poll") }
                guard ready > 0 else { continue }
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { return unavailable("transport_closed") }
                bytesRead += data.count
                guard bytesRead <= 1_048_576 else { return unavailable("response_too_large") }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { return unavailable("invalid_response") }
                    let step = exchange.receive(message)
                    for request in step.requests { try send(request) }
                    if let result = step.result {
                        if case .unavailable = result { return unavailable("rpc_or_schema") }
                        return result
                    }
                }
            }
        } catch {
            // RPC errors may contain account details; never log the raw response.
            return unavailable("launch_or_transport")
        }
        return unavailable("timeout")
    }
}

/// A small, testable JSON-RPC handshake. No login, model, or reset requests.
struct CodexQuotaExchange {
    private var expectedID = 1
    private var planType: String?

    var initialRequest: [String: Any] {
        ["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "token_meter", "title": "TokenMeter",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.3",
        ]]]
    }

    mutating func receive(_ message: [String: Any]) -> (requests: [[String: Any]], result: CodexQuotaReadResult?) {
        // Reject server-initiated requests without providing external auth material.
        if message["method"] != nil {
            if let id = message["id"] {
                return ([["id": id, "error": ["code": -32601, "message": "Unsupported method"]]], nil)
            }
            return ([], nil)
        }
        guard message["id"] as? Int == expectedID else { return ([], nil) }
        guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
            return ([], .unavailable)
        }
        switch expectedID {
        case 1:
            expectedID = 2
            return ([["method": "initialized"],
                     ["id": 2, "method": "account/read", "params": ["refreshToken": false]]], nil)
        case 2:
            guard let account = result["account"] as? [String: Any] else {
                return ([], result["account"] is NSNull ? .noSubscription : .unavailable)
            }
            guard let type = account["type"] as? String else { return ([], .unavailable) }
            if type == "apiKey" || type == "amazonBedrock" { return ([], .noSubscription) }
            guard type == "chatgpt" else { return ([], .unavailable) }
            planType = account["planType"] as? String
            if ["free", "go"].contains(planType?.lowercased() ?? "") { return ([], .noSubscription) }
            expectedID = 3
            return ([["id": 3, "method": "account/rateLimits/read"]], nil)
        default:
            guard let quota = Self.parseQuota(result, planType: planType) else { return ([], .unavailable) }
            return ([], .quota(quota))
        }
    }

    static func parseQuota(_ result: [String: Any], planType: String?, now: Date = Date()) -> CodexQuotaSnapshot? {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket: [String: Any]
        if let main = byID?["codex"] as? [String: Any] {
            guard main["limitId"] == nil || main["limitId"] is NSNull || main["limitId"] as? String == "codex" else { return nil }
            bucket = main
        } else if let legacy = result["rateLimits"] as? [String: Any], legacy["limitId"] as? String == "codex" {
            bucket = legacy
        } else { return nil }

        var windows: [CodexQuota.Window] = []
        for slot in ["primary", "secondary"] {
            guard let value = bucket[slot], !(value is NSNull) else { continue }
            guard let window = value as? [String: Any],
                  let used = window["usedPercent"] as? Double, used.isFinite, (0...100).contains(used),
                  let minutes = window["windowDurationMins"] as? Int, minutes > 0, minutes <= 525_600,
                  let reset = window["resetsAt"] as? Double, reset.isFinite, reset > now.timeIntervalSince1970
            else { return nil }
            windows.append(.init(sourceSlot: slot, usedPercent: used, windowMinutes: minutes,
                                 resetsAt: Date(timeIntervalSince1970: reset)))
        }
        guard !windows.isEmpty else { return nil }
        let snapshot = CodexQuotaSnapshot(windows: windows.sorted { $0.windowMinutes < $1.windowMinutes },
                                  planType: bucket["planType"] as? String ?? planType ?? "",
                                  model: "", timestamp: now, limitId: "codex")
        return snapshot.isTrusted ? snapshot : nil
    }
}

/// Stores quota values only, never account identifiers or authentication data.
actor CodexQuotaService {
    private let cacheURL: URL
    private var snapshot: CodexQuotaSnapshot?
    private var noSubscription = false
    private var lastAttempt: Date = .distantPast
    private var fetching = false
    private var lastReadSucceeded = false

    init(cacheURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("token-meter/codex_live_quota_v1.json")) {
        self.cacheURL = cacheURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? decoder.decode(CodexQuotaSnapshot.self, from: data), cached.isTrusted {
            snapshot = cached
        }
    }

    func refresh(now: Date = Date(), read: @escaping @Sendable () -> CodexQuotaReadResult = { CodexQuotaClient.read() }) async -> CodexQuotaReadResult {
        guard !fetching, now.timeIntervalSince(lastAttempt) >= 30 else { return currentResult }
        fetching = true
        lastAttempt = now
        let result = await Task.detached(priority: .utility) { read() }.value
        fetching = false
        switch result {
        case .quota(let quota):
            guard quota.isTrusted else { lastReadSucceeded = false; return currentResult }
            snapshot = quota
            noSubscription = false
            lastReadSucceeded = true
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(quota) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        case .noSubscription:
            snapshot = nil
            noSubscription = true
            lastReadSucceeded = false
            try? FileManager.default.removeItem(at: cacheURL)
        case .unavailable, .cached:
            lastReadSucceeded = false
        }
        return currentResult
    }

    private var currentResult: CodexQuotaReadResult {
        if noSubscription { return .noSubscription }
        if let snapshot { return lastReadSucceeded ? .quota(snapshot) : .cached(snapshot) }
        return .unavailable
    }
}

func displayedCodexQuota(live: CodexQuotaReadResult, local: CodexQuota?) -> CodexQuota? {
    switch live {
    case .quota(let snapshot):
        return resolvedLiveQuota(snapshot, local: local)
    case .cached(let snapshot):
        if let local, let observedAt = local.observedAt,
           observedAt > snapshot.timestamp, observedAt <= Date(),
           local.limitId == "codex", local.planType == snapshot.planType,
           CodexQuotaSnapshot(windows: local.windows, planType: local.planType, model: local.model,
                              timestamp: observedAt, limitId: local.limitId).isTrusted {
            // Replace the whole observation, including banked resets and window
            // changes. Never splice 5H and 7D windows from different observations.
            return local
        }
        return resolvedLiveQuota(snapshot, local: local)
    case .noSubscription, .unavailable:
        // Logs alone cannot establish an active subscription or current login.
        return nil
    }
}

private func resolvedLiveQuota(_ snapshot: CodexQuotaSnapshot, local: CodexQuota?) -> CodexQuota? {
    guard snapshot.isTrusted, !["free", "go"].contains(snapshot.planType.lowercased()) else { return nil }
    return CodexQuota(planType: snapshot.planType.isEmpty ? local?.planType ?? "" : snapshot.planType,
                      model: local?.model ?? "Codex", windows: snapshot.windows,
                      observedAt: snapshot.timestamp, limitId: snapshot.limitId)
}
