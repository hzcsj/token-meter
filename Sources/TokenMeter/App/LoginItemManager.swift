import Darwin
import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

protocol CommandExecuting {
    func run(_ executableURL: URL, arguments: [String]) throws -> CommandResult
}

struct ProcessCommandExecutor: CommandExecuting {
    func run(_ executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }
}

struct LaunchAgentRegistration: Equatable {
    let label: String
    let plistURL: URL
}

struct LoginItemConfiguration {
    let current: LaunchAgentRegistration
    let legacy: [LaunchAgentRegistration]
    let executableURL: URL
    let launchctlURL: URL
    let launchctlDomain: String

    init(
        label: String,
        legacyLabels: [String] = [],
        executableURL: URL,
        launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        userID: uid_t = getuid()
    ) {
        current = LaunchAgentRegistration(
            label: label,
            plistURL: launchAgentsDirectory.appendingPathComponent("\(label).plist")
        )
        legacy = legacyLabels.map {
            LaunchAgentRegistration(
                label: $0,
                plistURL: launchAgentsDirectory.appendingPathComponent("\($0).plist")
            )
        }
        self.executableURL = executableURL
        self.launchctlURL = launchctlURL
        launchctlDomain = "gui/\(userID)"
    }
}

protocol LoginItemManaging: AnyObject {
    func isEnabled() throws -> Bool
    func setEnabled(_ enabled: Bool) throws
    func reconcileLegacyRegistrations() throws
}

enum LoginItemError: LocalizedError {
    case launchctlFailed(arguments: [String], message: String)
    case verificationFailed(expectedEnabled: Bool)

    var errorDescription: String? {
        switch self {
        case let .launchctlFailed(arguments, message):
            let detail = message.isEmpty ? "未返回错误详情" : message
            return "launchctl \(arguments.joined(separator: " ")) 失败：\(detail)"
        case let .verificationFailed(expectedEnabled):
            return expectedEnabled
                ? "系统未保存“随系统启动”的开启状态"
                : "系统未保存“随系统启动”的关闭状态"
        }
    }
}

final class LoginItemManager: LoginItemManaging {
    private struct RegistrationFileSnapshot {
        let url: URL
        let data: Data?
    }

    private let configuration: LoginItemConfiguration
    private let commandExecutor: CommandExecuting
    private let fileManager: FileManager

    init(
        configuration: LoginItemConfiguration,
        commandExecutor: CommandExecuting = ProcessCommandExecutor(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.commandExecutor = commandExecutor
        self.fileManager = fileManager
    }

    /// This setting means “start after the current user logs in”. A valid plist
    /// plus launchd's persisted enable/disable override is the source of truth.
    func isEnabled() throws -> Bool {
        let configured = allRegistrations.filter(isConfigured)
        guard !configured.isEmpty else { return false }

        let disabled = try disabledLabels()
        return configured.contains { !disabled.contains($0.label) }
    }

    /// Writes the login-time definition and updates launchd's persistent
    /// override. It intentionally never loads, unloads, bootstraps, or kicks the
    /// job, so toggling cannot terminate this process or launch a second copy.
    func setEnabled(_ enabled: Bool) throws {
        let snapshots = try snapshotRegistrationFiles()
        let originalDisabled = try disabledLabels()

        do {
            try writeCurrentRegistration()
            try setLabel(configuration.current.label, enabled: enabled)

            for registration in configuration.legacy where fileManager.fileExists(atPath: registration.plistURL.path) {
                try setLabel(registration.label, enabled: false)
                try fileManager.removeItem(at: registration.plistURL)
            }

            guard try isEnabled() == enabled else {
                throw LoginItemError.verificationFailed(expectedEnabled: enabled)
            }
        } catch {
            restoreRegistrationFiles(from: snapshots)
            restoreDisabledLabels(originalDisabled)
            throw error
        }
    }

    /// Migrates known historical labels without loading either job. If both a
    /// current and legacy definition exist, the current label wins.
    func reconcileLegacyRegistrations() throws {
        let legacyFiles = configuration.legacy.filter {
            fileManager.fileExists(atPath: $0.plistURL.path)
        }
        guard !legacyFiles.isEmpty else { return }

        let snapshots = try snapshotRegistrationFiles()
        let originalDisabled = try disabledLabels()

        do {
            let currentExists = isConfigured(configuration.current)
            let shouldEnable: Bool
            if currentExists {
                shouldEnable = !originalDisabled.contains(configuration.current.label)
            } else {
                shouldEnable = legacyFiles.contains {
                    isConfigured($0) && !originalDisabled.contains($0.label)
                }
                try writeCurrentRegistration()
                try setLabel(configuration.current.label, enabled: shouldEnable)
            }

            for registration in legacyFiles {
                try setLabel(registration.label, enabled: false)
                try fileManager.removeItem(at: registration.plistURL)
            }

            guard try isEnabled() == shouldEnable else {
                throw LoginItemError.verificationFailed(expectedEnabled: shouldEnable)
            }
        } catch {
            restoreRegistrationFiles(from: snapshots)
            restoreDisabledLabels(originalDisabled)
            throw error
        }
    }

    private var allRegistrations: [LaunchAgentRegistration] {
        [configuration.current] + configuration.legacy
    }

    private func isConfigured(_ registration: LaunchAgentRegistration) -> Bool {
        guard
            let data = fileManager.contents(atPath: registration.plistURL.path),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = propertyList as? [String: Any],
            dictionary["Label"] as? String == registration.label,
            dictionary["RunAtLoad"] as? Bool == true,
            let arguments = dictionary["ProgramArguments"] as? [String],
            arguments.first?.isEmpty == false
        else {
            return false
        }

        return (dictionary["KeepAlive"] as? Bool) != true
    }

    private func writeCurrentRegistration() throws {
        let propertyList: [String: Any] = [
            "Label": configuration.current.label,
            "ProgramArguments": [configuration.executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try fileManager.createDirectory(
            at: configuration.current.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: configuration.current.plistURL, options: .atomic)
    }

    private func disabledLabels() throws -> Set<String> {
        let arguments = ["print-disabled", configuration.launchctlDomain]
        let result = try runLaunchctl(arguments)
        let output = result.standardOutput + "\n" + result.standardError

        return Set(allRegistrations.compactMap { registration in
            let escapedLabel = NSRegularExpression.escapedPattern(for: registration.label)
            let pattern = "\"\(escapedLabel)\"\\s*=>\\s*(?:true|disabled)"
            guard output.range(of: pattern, options: .regularExpression) != nil else {
                return nil
            }
            return registration.label
        })
    }

    private func setLabel(_ label: String, enabled: Bool) throws {
        let verb = enabled ? "enable" : "disable"
        _ = try runLaunchctl([verb, "\(configuration.launchctlDomain)/\(label)"])
    }

    private func runLaunchctl(_ arguments: [String]) throws -> CommandResult {
        let result = try commandExecutor.run(configuration.launchctlURL, arguments: arguments)
        guard result.exitCode == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoginItemError.launchctlFailed(
                arguments: arguments,
                message: message.isEmpty ? fallback : message
            )
        }
        return result
    }

    private func snapshotRegistrationFiles() throws -> [RegistrationFileSnapshot] {
        try allRegistrations.map { registration in
            let data = fileManager.fileExists(atPath: registration.plistURL.path)
                ? try Data(contentsOf: registration.plistURL)
                : nil
            return RegistrationFileSnapshot(url: registration.plistURL, data: data)
        }
    }

    private func restoreRegistrationFiles(from snapshots: [RegistrationFileSnapshot]) {
        for snapshot in snapshots {
            let url = snapshot.url
            let data = snapshot.data
            if let data {
                try? fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url, options: .atomic)
            } else if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func restoreDisabledLabels(_ disabled: Set<String>) {
        for registration in allRegistrations {
            try? setLabel(registration.label, enabled: !disabled.contains(registration.label))
        }
    }
}
