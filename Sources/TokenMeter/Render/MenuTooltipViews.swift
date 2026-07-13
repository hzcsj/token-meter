import AppKit
import CoreText

struct MenuTooltipRow: Equatable {
    let name: String
    let value: String
}

final class MenuTooltipValueField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        // NSTextField aligns typographic advances, whose trailing whitespace
        // varies by glyph sequence. Align the visible glyph bounds instead.
        guard let font, let textColor else { return }
        let attributed = NSAttributedString(
            string: stringValue,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let origin = NSPoint(
            x: bounds.maxX - glyphBounds.maxX,
            y: floor((bounds.height - attributed.size().height) / 2)
        )
        attributed.draw(at: origin)
    }
}

final class MenuTooltipTextField: NSTextField {
    let tooltipRows: [MenuTooltipRow]
    private var hoverTrackingArea: NSTrackingArea?

    init(text: String, tooltipRows: [MenuTooltipRow]) {
        self.tooltipRows = tooltipRows
        super.init(frame: .zero)
        stringValue = text
        setAccessibilityHelp(
            tooltipRows.map { "\($0.name)：\($0.value)" }.joined(separator: "，")
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        MenuTooltipPresenter.shared.show(rows: tooltipRows, relativeTo: self)
    }

    override func mouseExited(with event: NSEvent) {
        MenuTooltipPresenter.shared.hide(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            MenuTooltipPresenter.shared.unregister(self)
            MenuTooltipPresenter.shared.hide(for: self)
        } else {
            MenuTooltipPresenter.shared.register(self)
        }
    }
}

final class MenuSourceTooltipView: NSView {
    static let cornerRadius: CGFloat = 8

    let rows: [MenuTooltipRow]
    private(set) var nameFields: [NSTextField] = []
    private(set) var valueFields: [NSTextField] = []
    private(set) var separatorView: NSView?

    private let horizontalPadding: CGFloat = 11
    private let verticalPadding: CGFloat = 9
    private let columnGap: CGFloat = 18
    private let rowHeight: CGFloat = 18
    private let separatorSpace: CGFloat = 5

    init(rows: [MenuTooltipRow]) {
        self.rows = rows
        super.init(frame: .zero)
        buildView()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func buildView() {
        let regularFont = NSFont.systemFont(ofSize: 11)
        let totalFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let totalIndex = rows.indices.last
        let nameWidth = rows.enumerated().map { index, row in
            textWidth(row.name, font: index == totalIndex ? totalFont : regularFont)
        }.max() ?? 0
        let valueWidth = rows.enumerated().map { index, row in
            textWidth(row.value, font: index == totalIndex ? totalFont : regularFont)
        }.max() ?? 0
        let dividerSpace = rows.count > 1 ? separatorSpace : 0
        let naturalWidth = horizontalPadding * 2 + nameWidth + columnGap + valueWidth
        let width = max(150, naturalWidth)
        let height = verticalPadding * 2 + CGFloat(rows.count) * rowHeight + dividerSpace
        frame = NSRect(x: 0, y: 0, width: width, height: height)

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        layer?.zPosition = 10_000

        let valueX = width - horizontalPadding - valueWidth
        for (index, row) in rows.enumerated() {
            let isTotal = index == totalIndex
            let font = isTotal ? totalFont : regularFont
            let y: CGFloat
            if isTotal && rows.count > 1 {
                y = verticalPadding
            } else {
                y = height - verticalPadding - CGFloat(index + 1) * rowHeight
            }

            let nameField = tooltipField(
                row.name,
                font: font,
                color: isTotal ? .labelColor : .secondaryLabelColor,
                alignment: .left,
                frame: NSRect(x: horizontalPadding, y: y, width: nameWidth, height: rowHeight)
            )
            let valueField = tooltipField(
                row.value,
                font: font,
                color: .labelColor,
                alignment: .right,
                frame: NSRect(x: valueX, y: y, width: valueWidth, height: rowHeight)
            )
            nameFields.append(nameField)
            valueFields.append(valueField)
            addSubview(nameField)
            addSubview(valueField)
        }

        if rows.count > 1 {
            let separator = NSView(frame: NSRect(
                x: horizontalPadding,
                y: verticalPadding + rowHeight + 2,
                width: width - horizontalPadding * 2,
                height: 1
            ))
            separator.wantsLayer = true
            separatorView = separator
            addSubview(separator)
        }

        updateColors()
    }

    private func tooltipField(_ text: String, font: NSFont, color: NSColor,
                              alignment: NSTextAlignment, frame: NSRect) -> NSTextField {
        let field: NSTextField
        if alignment == .right {
            field = MenuTooltipValueField(labelWithString: text)
        } else {
            field = NSTextField(labelWithString: text)
        }
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.frame = frame
        field.lineBreakMode = .byClipping
        return field
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.98).cgColor
        layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.8).cgColor
        separatorView?.layer?.backgroundColor = NSColor.separatorColor
            .withAlphaComponent(0.65).cgColor
    }
}

private final class WeakTooltipField {
    weak var value: MenuTooltipTextField?

    init(_ value: MenuTooltipTextField) {
        self.value = value
    }
}

final class MenuTooltipPresenter: NSObject {
    static let shared = MenuTooltipPresenter()

    private weak var sourceView: NSView?
    private var tooltipView: MenuSourceTooltipView?
    private var pendingShow: Timer?
    private var hoverPoller: Timer?
    private var registeredFields: [WeakTooltipField] = []

    var isTooltipVisible: Bool { tooltipView?.superview != nil }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func register(_ field: MenuTooltipTextField) {
        compactRegisteredFields()
        if !registeredFields.contains(where: { $0.value === field }) {
            registeredFields.append(WeakTooltipField(field))
        }
        startPolling()
    }

    func unregister(_ field: MenuTooltipTextField) {
        registeredFields.removeAll { $0.value == nil || $0.value === field }
    }

    func registeredField(at screenPoint: NSPoint) -> MenuTooltipTextField? {
        compactRegisteredFields()
        return registeredFields.reversed().compactMap(\.value).first { field in
            guard !field.isHidden,
                  field.alphaValue > 0,
                  let window = field.window,
                  window.isVisible else { return false }
            let windowRect = field.convert(field.bounds, to: nil)
            return window.convertToScreen(windowRect).contains(screenPoint)
        }
    }

    func show(rows: [MenuTooltipRow], relativeTo source: NSView) {
        if sourceView === source && (pendingShow != nil || isTooltipVisible) { return }
        pendingShow?.invalidate()
        removeTooltipView()
        sourceView = source

        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self, weak source] _ in
            guard let self, let source, self.sourceView === source else { return }
            self.pendingShow = nil
            self.present(rows: rows, relativeTo: source)
        }
        pendingShow = timer
        scheduleInMenuTrackingModes(timer)
    }

    func hide(for source: NSView? = nil) {
        if let source, sourceView !== source { return }
        pendingShow?.invalidate()
        pendingShow = nil
        sourceView = nil
        removeTooltipView()
    }

    @objc private func menuDidBeginTracking() {
        startPolling()
    }

    @objc private func menuDidEndTracking() {
        hoverPoller?.invalidate()
        hoverPoller = nil
        hide()
    }

    @objc private func pollHover() {
        let hoveredField = registeredField(at: NSEvent.mouseLocation)
        if let hoveredField {
            show(rows: hoveredField.tooltipRows, relativeTo: hoveredField)
        } else {
            hide()
        }
    }

    private func startPolling() {
        guard hoverPoller == nil else { return }
        // NSMenu owns a nested event-tracking loop. Polling the registered
        // field frames avoids relying solely on child-view tracking events,
        // which are not delivered consistently by custom menu-item views.
        let timer = Timer(timeInterval: 0.05, target: self,
                          selector: #selector(pollHover), userInfo: nil, repeats: true)
        hoverPoller = timer
        scheduleInMenuTrackingModes(timer)
    }

    private func scheduleInMenuTrackingModes(_ timer: Timer) {
        // DispatchQueue.main.asyncAfter is starved while NSMenu is tracking;
        // timers must explicitly participate in the event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func compactRegisteredFields() {
        registeredFields.removeAll { $0.value == nil }
    }

    private func present(rows: [MenuTooltipRow], relativeTo source: NSView) {
        // Ordering a separate NSPanel ends NSMenu's nested tracking session.
        // Host the tooltip inside the popup window so hover remains active.
        guard let sourceWindow = source.window,
              let container = sourceWindow.contentView else { return }
        let content = MenuSourceTooltipView(rows: rows)

        let windowRect = source.convert(source.bounds, to: nil)
        let sourceRect = container.convert(windowRect, from: nil)
        let availableRect = container.bounds.insetBy(dx: 8, dy: 8)
        let size = content.frame.size
        var x = sourceRect.midX - size.width / 2
        var y = sourceRect.minY - size.height - 6
        if y < availableRect.minY {
            y = sourceRect.maxY + 6
        }
        x = min(max(x, availableRect.minX), availableRect.maxX - size.width)
        y = min(max(y, availableRect.minY), availableRect.maxY - size.height)

        content.setFrameOrigin(NSPoint(x: x, y: y))
        container.addSubview(content, positioned: .above, relativeTo: nil)
        tooltipView = content
    }

    private func removeTooltipView() {
        tooltipView?.removeFromSuperview()
        tooltipView = nil
    }
}
