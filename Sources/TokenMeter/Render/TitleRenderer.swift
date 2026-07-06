import AppKit

struct TitleRenderer {
    private static let fontPt: CGFloat = 10
    private static let heightPt: CGFloat = 22

    private static var font: NSFont {
        NSFont(name: "Menlo", size: fontPt)
            ?? NSFont.monospacedSystemFont(ofSize: fontPt, weight: .regular)
    }

    func renderLocalUsage(tokens: Int, cost: Double) -> NSImage {
        let tokenStr = humanizeTokens(tokens)
        let costStr = cost == 0 && tokens > 0 ? "Free" : "¥\(Int(cost))"
        return renderLines([tokenStr, costStr])
    }

    // MARK: - Private

    private func renderLines(_ lines: [String]) -> NSImage {
        let font = Self.font
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        var maxWidth: CGFloat = 0
        for line in lines {
            let w = (line as NSString).size(withAttributes: attrs).width
            maxWidth = max(maxWidth, w)
        }

        let lineCount = CGFloat(lines.count)
        let lineHeight = Self.heightPt / lineCount
        let width = maxWidth + 4

        let image = NSImage(size: NSSize(width: width, height: Self.heightPt))
        image.lockFocus()

        NSColor.black.setFill()

        for (index, line) in lines.enumerated() {
            let textSize = (line as NSString).size(withAttributes: attrs)
            let x = (width - textSize.width) / 2
            let y = Self.heightPt - CGFloat(index + 1) * lineHeight
                    + (lineHeight - textSize.height) / 2
            (line as NSString).draw(
                at: NSPoint(x: x, y: y),
                withAttributes: attrs
            )
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func humanizeTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1_000.0) }
        if count < 100_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000.0) }
        if count < 1_000_000_000 { return String(format: "%.0fM", Double(count) / 1_000_000.0) }
        return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
    }
}
