import AppKit

enum MenuLayout {
    static let leftPad: CGFloat = 12
    static let rightPad: CGFloat = 12
    static let rowHeight: CGFloat = 22
    static let verticalPad: CGFloat = 6
    static let safeMargin: CGFloat = 2
}

func textWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

private func fieldFrame(for font: NSFont, x: CGFloat, width: CGFloat) -> NSRect {
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    let fieldHeight = lineHeight + 4
    let y = floor((MenuLayout.rowHeight - fieldHeight) / 2) - 1
    return NSRect(x: x, y: y, width: width, height: fieldHeight)
}

private func makeField(text: String, font: NSFont, color: NSColor,
                       x: CGFloat, width: CGFloat, alignment: NSTextAlignment) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.backgroundColor = .clear
    field.drawsBackground = false
    field.isEditable = false
    field.isBordered = false
    field.alignment = alignment
    field.frame = fieldFrame(for: font, x: x, width: width)
    field.cell?.truncatesLastVisibleLine = false
    field.lineBreakMode = .byClipping
    return field
}

final class MenuTextRowView: NSView {
    override var allowsVibrancy: Bool { false }

    convenience init(text: String, font: NSFont, color: NSColor) {
        let tWidth = textWidth(text, font: font) + MenuLayout.safeMargin
        let width = tWidth + MenuLayout.leftPad + MenuLayout.rightPad

        self.init(frame: NSRect(x: 0, y: 0, width: width, height: MenuLayout.rowHeight))
        addSubview(makeField(text: text, font: font, color: color,
                             x: MenuLayout.leftPad, width: tWidth, alignment: .left))
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
}

final class MenuUsageRowView: NSView {
    override var allowsVibrancy: Bool { false }

    struct ColumnWidths {
        let labelWidth: CGFloat
        let tokenWidth: CGFloat
        let countWidth: CGFloat
        let costWidth: CGFloat
        let contentWidth: CGFloat

        static func calculate(labels: [String], usages: [DailyUsage], font: NSFont) -> ColumnWidths {
            let spaceWidth = textWidth(" ", font: font)
            let safe = MenuLayout.safeMargin

            let labelWidth = (labels.map { textWidth($0, font: font) }.max() ?? 0) + safe
            let tokenWidth = (usages.map { textWidth(humanizeTokens($0.tokens) + " Tok", font: font) }.max() ?? 0) + safe
            let countWidth = (usages.map { textWidth(humanizeCount($0.messageCount) + "次", font: font) }.max() ?? 0) + safe
            let costWidth  = (usages.map { textWidth(formatCost($0.costCNY, tokens: $0.tokens), font: font) }.max() ?? 0) + safe

            let contentWidth = labelWidth
                + spaceWidth * 2
                + tokenWidth
                + spaceWidth * 2
                + countWidth
                + spaceWidth * 2
                + costWidth

            return ColumnWidths(
                labelWidth: labelWidth,
                tokenWidth: tokenWidth,
                countWidth: countWidth,
                costWidth: costWidth,
                contentWidth: contentWidth
            )
        }
    }

    convenience init(label: String, tokens: String, count: String, cost: String,
                     font: NSFont, color: NSColor, columns: ColumnWidths) {
        let spaceWidth = textWidth(" ", font: font)
        let labelTokenGap = spaceWidth * 2
        let tokenCountGap = spaceWidth * 2

        let contentRight = MenuLayout.leftPad + columns.contentWidth
        let rowWidth = contentRight + MenuLayout.rightPad

        self.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: MenuLayout.rowHeight))

        let labelX = MenuLayout.leftPad
        addSubview(makeField(text: label, font: font, color: color,
                             x: labelX, width: columns.labelWidth, alignment: .left))

        let tokenX = labelX + columns.labelWidth + labelTokenGap
        addSubview(makeField(text: tokens + " Tok", font: font, color: color,
                             x: tokenX, width: columns.tokenWidth, alignment: .right))

        let countX = tokenX + columns.tokenWidth + tokenCountGap
        addSubview(makeField(text: count + "次", font: font, color: color,
                             x: countX, width: columns.countWidth, alignment: .right))

        let costX = contentRight - columns.costWidth
        addSubview(makeField(text: cost, font: font, color: color,
                             x: costX, width: columns.costWidth, alignment: .right))
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    private static func humanizeTokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1000.0) }
        if count < 100_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000.0) }
        if count < 1_000_000_000 { return String(format: "%.0fM", Double(count) / 1_000_000.0) }
        return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
    }

    private static func humanizeCount(_ count: Int) -> String {
        if count < 10_000 { return "\(count)" }
        return String(format: "%.1fk", Double(count) / 1000.0)
    }

    private static func formatCost(_ cost: Double, tokens: Int) -> String {
        if cost == 0 && tokens > 0 { return "Free" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "¥\(f.string(from: NSNumber(value: cost))!)"
    }
}

final class MenuQuotaRowView: NSView {
    override var allowsVibrancy: Bool { false }

    convenience init(left: String, right: String, font: NSFont, color: NSColor, contentWidth: CGFloat) {
        let rowWidth = MenuLayout.leftPad + contentWidth + MenuLayout.rightPad
        let contentRight = MenuLayout.leftPad + contentWidth

        self.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: MenuLayout.rowHeight))

        let leftWidth = textWidth(left, font: font) + MenuLayout.safeMargin
        addSubview(makeField(text: left, font: font, color: color,
                             x: MenuLayout.leftPad, width: leftWidth, alignment: .left))

        let rightWidth = textWidth(right, font: font) + MenuLayout.safeMargin
        addSubview(makeField(text: right, font: font, color: color,
                             x: contentRight - rightWidth, width: rightWidth, alignment: .right))
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
}

final class MenuPaddingView: NSView {
    override var allowsVibrancy: Bool { false }

    convenience init(height: CGFloat) {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: height))
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
}
