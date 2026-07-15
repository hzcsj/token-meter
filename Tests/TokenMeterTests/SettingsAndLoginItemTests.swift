import AppKit
import XCTest
@testable import TokenMeter

final class SettingsAndLoginItemTests: XCTestCase {
    func testEnableWritesLaunchAgentWithoutStartingAnotherProcess() throws {
        let fixture = try makeFixture(disabledLabels: ["io.github.example.current"])
        defer { fixture.cleanup() }

        try fixture.manager.setEnabled(true)

        XCTAssertTrue(try fixture.manager.isEnabled())
        let plist = try readPlist(fixture.currentPlist)
        XCTAssertEqual(plist["Label"] as? String, "io.github.example.current")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(
            (plist["ProgramArguments"] as? [String])?.first,
            fixture.executable.path
        )
        assertNoProcessLifecycleCommands(fixture.executor.invocations)
    }

    func testDisableKeepsCurrentProcessAndDefinitionConfigured() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.manager.setEnabled(true)
        fixture.executor.invocations.removeAll()

        try fixture.manager.setEnabled(false)

        XCTAssertFalse(try fixture.manager.isEnabled())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentPlist.path))
        XCTAssertTrue(fixture.executor.disabledLabels.contains("io.github.example.current"))
        assertNoProcessLifecycleCommands(fixture.executor.invocations)
    }

    func testLegacyMigrationPreservesEnabledStateAndPreventsCoexistence() throws {
        let fixture = try makeFixture(legacyLabels: ["com.user.tokenmeter"])
        defer { fixture.cleanup() }
        let legacyPlist = fixture.directory.appendingPathComponent("com.user.tokenmeter.plist")
        try writePlist(label: "com.user.tokenmeter", executable: fixture.executable, to: legacyPlist)
        fixture.executor.invocations.removeAll()

        try fixture.manager.reconcileLegacyRegistrations()

        XCTAssertTrue(try fixture.manager.isEnabled())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentPlist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlist.path))
        XCTAssertTrue(fixture.executor.disabledLabels.contains("com.user.tokenmeter"))
        assertNoProcessLifecycleCommands(fixture.executor.invocations)
    }

    func testFailedToggleRestoresPreviousActualState() throws {
        let fixture = try makeFixture(disabledLabels: ["io.github.example.current"])
        defer { fixture.cleanup() }
        try fixture.manager.setEnabled(false)
        fixture.executor.failVerb = "enable"

        XCTAssertThrowsError(try fixture.manager.setEnabled(true))
        XCTAssertFalse(try fixture.manager.isEnabled())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentPlist.path))
    }

    func testParentUsesNativeSubmenuWithoutIcon() throws {
        _ = NSApplication.shared
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: FakeLoginItemManager(enabled: true),
            errorReporter: { _ in XCTFail("Unexpected error") }
        )

        let parent = controller.makeParentMenuItem()

        XCTAssertEqual(parent.title, "设置与退出…")
        XCTAssertNil(parent.view)
        XCTAssertNil(parent.image)
        XCTAssertNotNil(parent.submenu)
    }

    func testSecondaryMenuUsesFixedItemsToggleViewAndCommandQ() throws {
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true)
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            errorReporter: { _ in XCTFail("Unexpected error") }
        )

        let menu = try XCTUnwrap(controller.makeParentMenuItem().submenu)
        controller.menuWillOpen(menu)

        XCTAssertEqual(menu.items.map(\.title), ["随系统启动", "", "退出 TokenMeter"])
        let toggleView = try XCTUnwrap(menu.items[0].view as? LoginItemToggleRowView)
        let quitView = try XCTUnwrap(menu.items[2].view as? SettingsMenuRowButton)
        XCTAssertTrue(waitUntil { toggleView.isOn == true })
        XCTAssertEqual(toggleView.isOn, true)
        XCTAssertEqual(toggleView.trailingText, "ON")
        XCTAssertEqual(quitView.trailingText, "⌘Q")
        XCTAssertEqual(toggleView.frame.width, quitView.frame.width)
        XCTAssertEqual(toggleView.frame.height, quitView.frame.height)
        XCTAssertNil(menu.items[0].action)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].keyEquivalent, "q")
        XCTAssertTrue(menu.items[2].keyEquivalentModifierMask.contains(.command))
    }

    func testToggleUpdatesOnlyStatusAndKeepsSubmenuAttached() throws {
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true)
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            errorReporter: { _ in XCTFail("Unexpected error") }
        )
        let parentMenu = NSMenu()
        let parentItem = controller.makeParentMenuItem()
        parentMenu.addItem(parentItem)
        let submenu = try XCTUnwrap(parentItem.submenu)
        let toggleView = try XCTUnwrap(submenu.items[0].view as? LoginItemToggleRowView)
        controller.menuWillOpen(submenu)
        XCTAssertTrue(waitUntil { toggleView.isOn == true })

        XCTAssertTrue(toggleView.accessibilityPerformPress())

        XCTAssertEqual(toggleView.isOn, false)
        XCTAssertEqual(toggleView.trailingText, "OFF")
        XCTAssertTrue(waitUntil { !loginItems.enabled })
        XCTAssertEqual(loginItems.setValues, [false])
        XCTAssertTrue(parentItem.submenu === submenu)
        XCTAssertTrue(submenu.supermenu === parentMenu)
    }

    func testToggleSupportsControlKeyboardAndVoiceOver() throws {
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true)
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            errorReporter: { _ in XCTFail("Unexpected error") }
        )
        let submenu = try XCTUnwrap(controller.makeParentMenuItem().submenu)
        let toggleView = try XCTUnwrap(submenu.items[0].view as? LoginItemToggleRowView)
        controller.menuWillOpen(submenu)
        XCTAssertTrue(waitUntil { toggleView.isOn == true })
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        toggleView.performClick(nil)
        XCTAssertEqual(toggleView.isOn, false)
        XCTAssertEqual(toggleView.trailingText, "OFF")

        toggleView.keyDown(with: returnKey)
        XCTAssertEqual(toggleView.isOn, true)
        XCTAssertEqual(toggleView.trailingText, "ON")

        XCTAssertTrue(toggleView.accessibilityPerformPress())
        XCTAssertEqual(toggleView.isOn, false)
        XCTAssertEqual(toggleView.trailingText, "OFF")
        XCTAssertTrue(waitUntil { !loginItems.enabled })
        XCTAssertEqual(loginItems.setValues, [false])
    }

    func testSlowLoginItemUpdateDoesNotBlockMenuEventsOrVisualState() throws {
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true, setDelay: 0.3)
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            loginItemUpdateDelay: 0,
            errorReporter: { _ in XCTFail("Unexpected error") }
        )
        let submenu = try XCTUnwrap(controller.makeParentMenuItem().submenu)
        let toggleView = try XCTUnwrap(submenu.items[0].view as? LoginItemToggleRowView)
        controller.menuWillOpen(submenu)
        XCTAssertTrue(waitUntil { toggleView.isOn == true })
        let pointerEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        let start = Date()
        toggleView.performClick(nil)
        let actionDuration = Date().timeIntervalSince(start)

        XCTAssertLessThan(actionDuration, 0.1)
        XCTAssertEqual(toggleView.isOn, false)
        XCTAssertEqual(toggleView.trailingText, "OFF")
        toggleView.mouseEntered(with: pointerEvent)
        XCTAssertTrue(toggleView.isShowingSelectionBackground)
        toggleView.mouseExited(with: pointerEvent)
        XCTAssertFalse(toggleView.isShowingSelectionBackground)
        XCTAssertTrue(waitUntil(timeout: 1) { !loginItems.enabled })
    }

    func testFailedAsyncToggleRestoresActualState() throws {
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true, failsSet: true)
        var didReportError = false
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            loginItemUpdateDelay: 0,
            errorReporter: { _ in didReportError = true }
        )
        let submenu = try XCTUnwrap(controller.makeParentMenuItem().submenu)
        let toggleView = try XCTUnwrap(submenu.items[0].view as? LoginItemToggleRowView)
        controller.menuWillOpen(submenu)
        XCTAssertTrue(waitUntil { toggleView.isOn == true })

        toggleView.performClick(nil)

        XCTAssertEqual(toggleView.isOn, false)
        XCTAssertTrue(waitUntil { didReportError && toggleView.isOn == true })
        XCTAssertTrue(loginItems.enabled)
    }

    func testMenuRenderGateDefersReplacementUntilTrackedMenuCloses() {
        let gate = MenuRenderGate()

        XCTAssertTrue(gate.requestRender())
        gate.menuWillOpen()
        XCTAssertTrue(gate.isTrackingMenu)
        XCTAssertFalse(gate.requestRender())
        XCTAssertFalse(gate.requestRender())
        XCTAssertTrue(gate.menuDidClose())
        XCTAssertFalse(gate.isTrackingMenu)
        XCTAssertFalse(gate.menuDidClose())
        XCTAssertTrue(gate.requestRender())
    }

    func testSubmenuRowsShowSelectionBackgroundOnlyWhileFocused() throws {
        _ = NSApplication.shared
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: FakeLoginItemManager(enabled: true),
            errorReporter: { _ in XCTFail("Unexpected error") }
        )
        let submenu = try XCTUnwrap(controller.makeParentMenuItem().submenu)
        let toggleView = try XCTUnwrap(submenu.items[0].view as? LoginItemToggleRowView)
        let quitView = try XCTUnwrap(submenu.items[2].view as? SettingsMenuRowButton)
        let pointerEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        for row in [toggleView, quitView] {
            XCTAssertFalse(row.isShowingSelectionBackground)
            XCTAssertTrue(row.currentTrailingTextColor.isEqual(NSColor.labelColor))
            row.mouseEntered(with: pointerEvent)
            XCTAssertTrue(row.isShowingSelectionBackground)
            XCTAssertTrue(
                row.currentTrailingTextColor.isEqual(NSColor.selectedMenuItemTextColor)
            )
            row.mouseExited(with: pointerEvent)
            XCTAssertFalse(row.isShowingSelectionBackground)
            XCTAssertTrue(row.currentTrailingTextColor.isEqual(NSColor.labelColor))
        }
    }

    func testQuitDoesNotChangeLoginItemSetting() throws {
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true)
        var terminationCount = 0
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            errorReporter: { _ in XCTFail("Unexpected error") },
            terminationHandler: { terminationCount += 1 }
        )
        let submenu = try XCTUnwrap(controller.makeParentMenuItem().submenu)
        let quitView = try XCTUnwrap(submenu.items[2].view as? SettingsMenuRowButton)

        quitView.performClick(nil)

        XCTAssertEqual(terminationCount, 1)
        XCTAssertTrue(loginItems.enabled)
        XCTAssertEqual(loginItems.setValues, [])
    }

    func testRepeatedControlClicksDoNotEndTrackedSubmenu() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
            "Requires an interactive WindowServer session"
        )
        _ = NSApplication.shared
        let loginItems = FakeLoginItemManager(enabled: true)
        let controller = SettingsMenuController(
            appName: "TokenMeter",
            loginItemManager: loginItems,
            errorReporter: { _ in XCTFail("Unexpected error") }
        )
        let parentItem = controller.makeParentMenuItem()
        let submenu = try XCTUnwrap(parentItem.submenu)
        let toggleView = try XCTUnwrap(submenu.items[0].view as? LoginItemToggleRowView)
        let parentMenu = NSMenu()
        parentMenu.addItem(parentItem)
        controller.menuWillOpen(submenu)
        XCTAssertTrue(waitUntil { toggleView.isOn == true })

        var didPresentMenu = false
        var completedClickCount = 0
        var remainedVisible = false
        let clickTimer = Timer(timeInterval: 0.05, repeats: true) { timer in
            if toggleView.window?.isVisible == true {
                didPresentMenu = true
            }
            guard completedClickCount < 6 else {
                timer.invalidate()
                return
            }
            if self.performTrackedClick(
                on: toggleView,
                eventNumber: completedClickCount + 1
            ) {
                completedClickCount += 1
            }
        }
        let inspectTimer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard completedClickCount == 6 else { return }
            remainedVisible = toggleView.window?.isVisible == true
            timer.invalidate()
            submenu.cancelTracking()
        }
        let watchdog = Timer(timeInterval: 1.5, repeats: false) { _ in
            submenu.cancelTracking()
        }
        RunLoop.main.add(clickTimer, forMode: .eventTracking)
        RunLoop.main.add(inspectTimer, forMode: .eventTracking)
        RunLoop.main.add(watchdog, forMode: .eventTracking)
        defer {
            clickTimer.invalidate()
            inspectTimer.invalidate()
            watchdog.invalidate()
        }

        let mouse = NSEvent.mouseLocation
        submenu.popUp(positioning: submenu.items[0], at: mouse, in: nil)

        try XCTSkipIf(!didPresentMenu, "WindowServer did not present the tracked menu")
        XCTAssertEqual(completedClickCount, 6)
        XCTAssertTrue(remainedVisible)
        XCTAssertTrue(waitUntil { loginItems.setValues.count == 1 })
        XCTAssertTrue(loginItems.enabled)
        XCTAssertEqual(loginItems.setValues, [true])
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func makeFixture(
        disabledLabels: Set<String> = [],
        legacyLabels: [String] = []
    ) throws -> LoginItemFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-meter-login-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("TokenMeter")
        let executor = FakeLaunchctlExecutor(disabledLabels: disabledLabels)
        let configuration = LoginItemConfiguration(
            label: "io.github.example.current",
            legacyLabels: legacyLabels,
            executableURL: executable,
            launchAgentsDirectory: directory,
            launchctlURL: URL(fileURLWithPath: "/bin/launchctl"),
            userID: 501
        )
        return LoginItemFixture(
            directory: directory,
            executable: executable,
            currentPlist: directory.appendingPathComponent("io.github.example.current.plist"),
            executor: executor,
            manager: LoginItemManager(configuration: configuration, commandExecutor: executor)
        )
    }

    private func writePlist(label: String, executable: URL, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": label,
                "ProgramArguments": [executable.path],
                "RunAtLoad": true,
                "KeepAlive": false
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func assertNoProcessLifecycleCommands(
        _ invocations: [[String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = Set(["load", "unload", "bootstrap", "bootout", "kickstart", "remove"])
        XCTAssertTrue(
            invocations.allSatisfy { invocation in
                guard let verb = invocation.first else { return true }
                return !forbidden.contains(verb)
            },
            "Unexpected launchctl lifecycle command: \(invocations)",
            file: file,
            line: line
        )
    }

    private func performTrackedClick(on button: NSButton, eventNumber: Int) -> Bool {
        guard let window = button.window else { return false }
        let location = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard
            let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber * 2,
                clickCount: eventNumber,
                pressure: 1
            ),
            let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: location,
                modifierFlags: [],
                timestamp: timestamp + 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber * 2 + 1,
                clickCount: eventNumber,
                pressure: 0
            )
        else { return false }

        NSApp.postEvent(mouseUp, atStart: true)
        button.mouseDown(with: mouseDown)
        return true
    }

}

private struct LoginItemFixture {
    let directory: URL
    let executable: URL
    let currentPlist: URL
    let executor: FakeLaunchctlExecutor
    let manager: LoginItemManager

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class FakeLaunchctlExecutor: CommandExecuting {
    var disabledLabels: Set<String>
    var failVerb: String?
    var invocations: [[String]] = []

    init(disabledLabels: Set<String>) {
        self.disabledLabels = disabledLabels
    }

    func run(_ executableURL: URL, arguments: [String]) throws -> CommandResult {
        invocations.append(arguments)
        guard let verb = arguments.first else {
            return CommandResult(exitCode: 2, standardOutput: "", standardError: "missing verb")
        }
        if verb == failVerb {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "injected failure")
        }

        switch verb {
        case "print-disabled":
            let entries = disabledLabels.sorted().map { "    \"\($0)\" => disabled" }
            return CommandResult(
                exitCode: 0,
                standardOutput: "disabled services = {\n\(entries.joined(separator: "\n"))\n}",
                standardError: ""
            )
        case "enable", "disable":
            let label = arguments.last?.split(separator: "/").last.map(String.init) ?? ""
            if verb == "enable" {
                disabledLabels.remove(label)
            } else {
                disabledLabels.insert(label)
            }
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        default:
            return CommandResult(exitCode: 2, standardOutput: "", standardError: "unexpected verb")
        }
    }
}

private enum FakeLoginItemError: Error {
    case setFailed
}

private final class FakeLoginItemManager: LoginItemManaging {
    private let lock = NSLock()
    private var storedEnabled: Bool
    private var storedSetValues: [Bool] = []
    private let setDelay: TimeInterval
    private let failsSet: Bool

    var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedEnabled
    }

    var setValues: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedSetValues
    }

    init(enabled: Bool, setDelay: TimeInterval = 0, failsSet: Bool = false) {
        storedEnabled = enabled
        self.setDelay = setDelay
        self.failsSet = failsSet
    }

    func isEnabled() throws -> Bool {
        enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if setDelay > 0 {
            Thread.sleep(forTimeInterval: setDelay)
        }
        lock.lock()
        defer { lock.unlock() }
        storedSetValues.append(enabled)
        guard !failsSet else { throw FakeLoginItemError.setFailed }
        storedEnabled = enabled
    }

    func reconcileLegacyRegistrations() throws {}
}
