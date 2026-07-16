import AppKit

private struct LoginItemOperationFailure: Error {
    let underlyingError: Error
    let actualState: Bool?
}

private final class LoginItemOperationCoordinator {
    private struct SetRequest {
        let enabled: Bool
        let revision: UInt
        let completion: (UInt, Result<Bool, LoginItemOperationFailure>) -> Void
    }

    private let loginItemManager: LoginItemManaging
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let coalescingDelay: TimeInterval
    private var pendingSetRequest: SetRequest?

    init(
        loginItemManager: LoginItemManaging,
        coalescingDelay: TimeInterval,
        callbackQueue: DispatchQueue = .main
    ) {
        self.loginItemManager = loginItemManager
        self.coalescingDelay = coalescingDelay
        self.callbackQueue = callbackQueue
        workQueue = DispatchQueue(
            label: "TokenMeter.LoginItemOperationCoordinator",
            qos: .userInitiated
        )
    }

    func readState(
        revision: UInt,
        completion: @escaping (UInt, Result<Bool, Error>) -> Void
    ) {
        workQueue.async { [loginItemManager, callbackQueue] in
            let result = Result { try loginItemManager.isEnabled() }
            callbackQueue.async {
                completion(revision, result)
            }
        }
    }

    func setEnabled(
        _ enabled: Bool,
        revision: UInt,
        completion: @escaping (UInt, Result<Bool, LoginItemOperationFailure>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let request = SetRequest(
                enabled: enabled,
                revision: revision,
                completion: completion
            )
            pendingSetRequest = request

            workQueue.asyncAfter(deadline: .now() + coalescingDelay) { [weak self] in
                guard
                    let self,
                    let pendingSetRequest,
                    pendingSetRequest.revision == request.revision
                else { return }

                self.pendingSetRequest = nil
                let result: Result<Bool, LoginItemOperationFailure>
                do {
                    try loginItemManager.setEnabled(pendingSetRequest.enabled)
                    result = .success(pendingSetRequest.enabled)
                } catch {
                    result = .failure(
                        LoginItemOperationFailure(
                            underlyingError: error,
                            actualState: try? loginItemManager.isEnabled()
                        )
                    )
                }

                callbackQueue.async {
                    pendingSetRequest.completion(pendingSetRequest.revision, result)
                }
            }
        }
    }
}

final class SettingsMenuController: NSObject, NSMenuDelegate {
    static let parentTitle = "设置与退出…"
    static let loginItemTitle = "随系统启动"

    typealias ErrorReporter = (Error) -> Void

    private let appName: String
    private let loginItemOperations: LoginItemOperationCoordinator
    private let errorReporter: ErrorReporter
    private let terminationHandler: () -> Void

    private let submenu = NSMenu()
    private lazy var loginItem = makeLoginItem()
    private lazy var quitItem = makeQuitItem()
    private weak var loginItemView: LoginItemToggleRowView?
    private var loginItemStateRevision: UInt = 0
    private var isRefreshingLoginItemState = false
    private var pendingLoginItemState: Bool?

    init(
        appName: String,
        loginItemManager: LoginItemManaging,
        loginItemUpdateDelay: TimeInterval = 0.08,
        errorReporter: @escaping ErrorReporter = SettingsMenuController.presentError,
        terminationHandler: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.appName = appName
        loginItemOperations = LoginItemOperationCoordinator(
            loginItemManager: loginItemManager,
            coalescingDelay: loginItemUpdateDelay
        )
        self.errorReporter = errorReporter
        self.terminationHandler = terminationHandler
        super.init()

        submenu.autoenablesItems = false
        submenu.delegate = self
        submenu.addItem(loginItem)
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(quitItem)
        refreshLoginItemState()
    }

    func makeParentMenuItem() -> NSMenuItem {
        if let previousMenu = submenu.supermenu,
           let previousParent = previousMenu.items.first(where: { $0.submenu === submenu }) {
            previousParent.submenu = nil
        }
        let item = NSMenuItem(title: Self.parentTitle, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        refreshLoginItemState()
    }

    func toggleLoginItem() {
        let currentValue = pendingLoginItemState ?? loginItemView?.isOn ?? false
        let requestedValue = !currentValue
        loginItemStateRevision &+= 1
        let revision = loginItemStateRevision

        pendingLoginItemState = requestedValue
        loginItemView?.isOn = requestedValue

        loginItemOperations.setEnabled(requestedValue, revision: revision) { [weak self] revision, result in
            guard let self, revision == loginItemStateRevision else { return }
            pendingLoginItemState = nil

            switch result {
            case let .success(actualState):
                loginItemView?.isOn = actualState
            case let .failure(failure):
                loginItemView?.isOn = failure.actualState
                print("无法更新“随系统启动”：\(failure.underlyingError.localizedDescription)")
                errorReporter(failure.underlyingError)
            }
        }
    }

    @objc func quitApplication(_ sender: Any?) {
        terminationHandler()
    }

    private func makeLoginItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.loginItemTitle, action: nil, keyEquivalent: "")
        let view = LoginItemToggleRowView(title: Self.loginItemTitle)
        view.target = self
        view.action = #selector(toggleLoginItemFromControl(_:))
        item.view = view
        item.isEnabled = true
        loginItemView = view
        return item
    }

    private func makeQuitItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "退出 \(appName)",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        item.keyEquivalentModifierMask = .command
        item.target = self
        item.isEnabled = true
        let view = SettingsMenuRowButton(title: item.title, trailingText: "⌘Q")
        view.target = self
        view.action = #selector(quitApplication(_:))
        view.setAccessibilityHelp("退出 \(appName)，快捷键 Command Q")
        item.view = view
        return item
    }

    private func refreshLoginItemState() {
        guard pendingLoginItemState == nil, !isRefreshingLoginItemState else { return }
        isRefreshingLoginItemState = true
        loginItemStateRevision &+= 1
        let revision = loginItemStateRevision

        loginItemOperations.readState(revision: revision) { [weak self] revision, result in
            guard let self else { return }
            isRefreshingLoginItemState = false
            guard revision == loginItemStateRevision, pendingLoginItemState == nil else { return }

            switch result {
            case let .success(actualState):
                loginItemView?.isOn = actualState
            case let .failure(error):
                loginItemView?.isOn = nil
                print("无法读取“随系统启动”状态：\(error.localizedDescription)")
            }
        }
    }

    @objc private func toggleLoginItemFromControl(_ sender: NSButton) {
        toggleLoginItem()
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法更新“随系统启动”"
        alert.informativeText = "\(error.localizedDescription)\n\n菜单已重新读取系统中的实际状态，请重试或查看控制台日志。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

class SettingsMenuRowButton: NSButton {
    private enum Layout {
        static let minimumWidth: CGFloat = 250
        static let height: CGFloat = 24
        static let leadingInset: CGFloat = 18
        static let trailingInset: CGFloat = 18
        static let highlightHorizontalInset: CGFloat = 5
        static let highlightVerticalInset: CGFloat = 1
        static let highlightRadius: CGFloat = 4
    }

    private let rowTitle: String
    private var trackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    var trailingText: String {
        didSet {
            guard oldValue != trailingText else { return }
            needsDisplay = true
        }
    }

    var isShowingSelectionBackground: Bool {
        isPointerInside
            || isHighlighted
            || enclosingMenuItem?.isHighlighted == true
            || window?.firstResponder === self
    }

    var currentTrailingTextColor: NSColor {
        isShowingSelectionBackground
            ? NSColor.selectedMenuItemTextColor
            : NSColor.labelColor
    }

    init(title: String, trailingText: String) {
        rowTitle = title
        self.trailingText = trailingText
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.minimumWidth, height: Layout.height))
        autoresizingMask = [.width]
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isPointerInside = false
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: // Return, Space, Enter
            performClick(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isShowingSelectionBackground {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(
                    dx: Layout.highlightHorizontalInset,
                    dy: Layout.highlightVerticalInset
                ),
                xRadius: Layout.highlightRadius,
                yRadius: Layout.highlightRadius
            ).fill()
        }

        let font = NSFont.menuFont(ofSize: 13)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isShowingSelectionBackground
                ? NSColor.selectedMenuItemTextColor
                : NSColor.labelColor
        ]
        let trailingAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: currentTrailingTextColor
        ]

        let titleSize = (rowTitle as NSString).size(withAttributes: titleAttributes)
        let titleRect = NSRect(
            x: Layout.leadingInset,
            y: (bounds.height - titleSize.height) / 2,
            width: max(0, bounds.width - Layout.leadingInset - Layout.trailingInset),
            height: titleSize.height
        )
        (rowTitle as NSString).draw(in: titleRect, withAttributes: titleAttributes)

        let trailingSize = (trailingText as NSString).size(withAttributes: trailingAttributes)
        (trailingText as NSString).draw(
            at: NSPoint(
                x: bounds.width - Layout.trailingInset - trailingSize.width,
                y: (bounds.height - trailingSize.height) / 2
            ),
            withAttributes: trailingAttributes
        )
    }
}

final class LoginItemToggleRowView: SettingsMenuRowButton {
    var isOn: Bool? {
        didSet {
            guard oldValue != isOn else { return }
            trailingText = statusText
            updateAccessibilityValue()
        }
    }

    init(title: String) {
        super.init(title: title, trailingText: "—")
        setAccessibilityHelp("切换随系统启动")
        updateAccessibilityValue()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private var statusText: String {
        guard let isOn else { return "—" }
        return isOn ? "ON" : "OFF"
    }

    private func updateAccessibilityValue() {
        let value: String
        switch isOn {
        case .some(true):
            value = "已开启"
        case .none:
            value = "状态未知"
        case .some(false):
            value = "已关闭"
        }
        setAccessibilityValue(value)
    }
}
