import AppKit

struct MenuBuilder {
    private let monoFont = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let smallFont = NSFont(name: "Menlo", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func build(
        claudeUsage: UsageSummary?,
        codexUsage: UsageSummary?,
        codexQuota: CodexQuota?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addVerticalPadding(to: menu)

        let mergedUsage = mergeUsage(claude: claudeUsage, codex: codexUsage)
        let columns = mergedUsage.map { calculateColumns(usage: $0) }

        if let quota = codexQuota {
            addCodexQuotaSection(quota, to: menu, columns: columns)
            menu.addItem(NSMenuItem.separator())
        }

        if let usage = mergedUsage {
            addLocalUsageSection(usage, to: menu, columns: columns!)
        }

        menu.addItem(NSMenuItem.separator())

        addActionButton("🔄 立即刷新", action: #selector(StatusBarManager.refresh), to: menu)

        addVerticalPadding(to: menu)

        return menu
    }

    // MARK: - Column Calculation

    private func calculateColumns(usage: UsageSummary) -> MenuUsageRowView.ColumnWidths {
        var allUsages: [DailyUsage] = []
        for day in usage.byDay.prefix(7) {
            allUsages.append(day)
        }
        allUsages.append(usage.weekTotal)
        allUsages.append(usage.monthTotal)
        allUsages.append(usage.allTimeTotal)

        var labels: [String] = []
        for day in usage.byDay.prefix(7) {
            labels.append(day.label)
        }
        labels.append("近7天累计")
        labels.append("当月累计")
        labels.append("历史累计")

        return MenuUsageRowView.ColumnWidths.calculate(labels: labels, usages: allUsages, font: monoFont)
    }

    // MARK: - Codex Quota Section

    private func addCodexQuotaSection(_ quota: CodexQuota, to menu: NSMenu, columns: MenuUsageRowView.ColumnWidths?) {
        let title = "🔋 Codex 额度 (\(quota.planType) · \(quota.model))"
        addTextRow(title, color: .secondary, font: smallFont, to: menu)

        let contentWidth = columns?.contentWidth ?? fallbackContentWidth()

        let primaryDisplay = quota.primary.displayData
        let primaryLeft = "5H 额度剩余：\(String(format: "%3.0f", primaryDisplay.remainingPercent))%"
        let primaryTimePercentStr = formatTimePercent(primaryDisplay.timePercent)
        let primaryRight = "\(primaryDisplay.countdown)  (\(primaryTimePercentStr))"
        let primaryColor: MenuColor = primaryDisplay.remainingPercent < primaryDisplay.timePercent ? .red : .primary

        let primaryItem = NSMenuItem()
        let primaryView = MenuQuotaRowView(left: primaryLeft, right: primaryRight, font: monoFont, color: primaryColor.nsColor, contentWidth: contentWidth)
        primaryItem.view = primaryView
        menu.addItem(primaryItem)

        let secondaryDisplay = quota.secondary.displayData
        let secondaryLeft = "7D 额度剩余：\(String(format: "%3.0f", secondaryDisplay.remainingPercent))%"
        let secondaryTimePercentStr = formatTimePercent(secondaryDisplay.timePercent)
        let secondaryRight = "\(secondaryDisplay.countdown)  (\(secondaryTimePercentStr))"
        let secondaryColor: MenuColor = secondaryDisplay.remainingPercent < secondaryDisplay.timePercent ? .red : .primary

        let secondaryItem = NSMenuItem()
        let secondaryView = MenuQuotaRowView(left: secondaryLeft, right: secondaryRight, font: monoFont, color: secondaryColor.nsColor, contentWidth: contentWidth)
        secondaryItem.view = secondaryView
        menu.addItem(secondaryItem)
    }

    private func formatTimePercent(_ percent: Double) -> String {
        if percent < 10 {
            return String(format: "%.2f%%", percent)
        } else {
            return String(format: "%.1f%%", percent)
        }
    }

    private func fallbackContentWidth() -> CGFloat {
        let spaceWidth = textWidth(" ", font: monoFont)
        let sampleTexts = ["226.1M Tok", "180次", "¥1,854.24", "今日 (周四)"]
        let widths = sampleTexts.map { textWidth($0, font: monoFont) }
        return widths.reduce(0, +) + spaceWidth * 4
    }

    // MARK: - Local Usage Section

    private func addLocalUsageSection(_ usage: UsageSummary, to menu: NSMenu, columns: MenuUsageRowView.ColumnWidths) {
        let title = "📈 本地用量统计"
        addTextRow(title, color: .secondary, font: smallFont, to: menu)

        for day in usage.byDay.prefix(7) {
            addUsageRow(day, font: monoFont, color: .primary, columns: columns, to: menu)
        }

        menu.addItem(NSMenuItem.separator())

        addUsageRow(usage.weekTotal, label: "近7天累计", font: monoFont, color: .primary, columns: columns, to: menu)
        addUsageRow(usage.monthTotal, label: "当月累计", font: monoFont, color: .primary, columns: columns, to: menu)
        addUsageRow(usage.allTimeTotal, label: "历史累计", font: monoFont, color: .primary, columns: columns, to: menu)
    }

    private func addUsageRow(_ usage: DailyUsage, label: String? = nil, font: NSFont, color: MenuColor, columns: MenuUsageRowView.ColumnWidths, to menu: NSMenu) {
        let labelText = label ?? usage.label
        let tokenText = humanizeTokens(usage.tokens)
        let countText = humanizeCount(usage.messageCount)
        let costText = formatCost(usage.costCNY, tokens: usage.tokens)

        let item = NSMenuItem()
        let rowView = MenuUsageRowView(
            label: labelText,
            tokens: tokenText,
            count: countText,
            cost: costText,
            font: font,
            color: color.nsColor,
            columns: columns
        )
        item.view = rowView
        menu.addItem(item)
    }

    // MARK: - Merge Usage

    func mergeUsage(claude: UsageSummary?, codex: UsageSummary?) -> UsageSummary? {
        if claude == nil && codex == nil {
            return nil
        }

        var mergedByDay: [String: (tokens: Int, cost: Double, messages: Int)] = [:]

        if let claude = claude {
            for day in claude.byDay {
                mergedByDay[day.date] = (
                    tokens: day.tokens,
                    cost: day.costCNY,
                    messages: day.messageCount
                )
            }
        }

        if let codex = codex {
            for day in codex.byDay {
                if let existing = mergedByDay[day.date] {
                    mergedByDay[day.date] = (
                        tokens: existing.tokens + day.tokens,
                        cost: existing.cost + day.costCNY,
                        messages: existing.messages + day.messageCount
                    )
                } else {
                    mergedByDay[day.date] = (
                        tokens: day.tokens,
                        cost: day.costCNY,
                        messages: day.messageCount
                    )
                }
            }
        }

        let byDay = mergedByDay.map { (date, data) in
            DailyUsage(
                date: date,
                tokens: data.tokens,
                costCNY: data.cost,
                messageCount: data.messages
            )
        }.sorted { $0.date > $1.date }

        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let todayStr = DateFormatter.yyyyMMdd.string(from: today)

        var recent7Days: [String] = []
        for i in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                recent7Days.append(DateFormatter.yyyyMMdd.string(from: date))
            }
        }

        let weekRows = byDay.filter { recent7Days.contains($0.date) }
        let weekTotal = DailyUsage(
            date: "week",
            tokens: weekRows.reduce(0) { $0 + $1.tokens },
            costCNY: weekRows.reduce(0.0) { $0 + $1.costCNY },
            messageCount: weekRows.reduce(0) { $0 + $1.messageCount }
        )

        let monthPrefix = String(todayStr.prefix(7))
        let monthRows = byDay.filter { $0.date.hasPrefix(monthPrefix) }
        let monthTotal = DailyUsage(
            date: "month",
            tokens: monthRows.reduce(0) { $0 + $1.tokens },
            costCNY: monthRows.reduce(0.0) { $0 + $1.costCNY },
            messageCount: monthRows.reduce(0) { $0 + $1.messageCount }
        )

        let allTimeTotal = DailyUsage(
            date: "all",
            tokens: byDay.reduce(0) { $0 + $1.tokens },
            costCNY: byDay.reduce(0.0) { $0 + $1.costCNY },
            messageCount: byDay.reduce(0) { $0 + $1.messageCount }
        )

        return UsageSummary(
            byDay: byDay,
            weekTotal: weekTotal,
            monthTotal: monthTotal,
            allTimeTotal: allTimeTotal
        )
    }

    // MARK: - Action Buttons

    private func addActionButton(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = StatusBarManager.shared
        menu.addItem(item)
    }

    // MARK: - Helpers

    private func addTextRow(_ text: String, color: MenuColor, font: NSFont, to menu: NSMenu) {
        let item = NSMenuItem()
        let rowView = MenuTextRowView(text: text, font: font, color: color.nsColor)
        item.view = rowView
        menu.addItem(item)
    }

    private func addVerticalPadding(to menu: NSMenu) {
        let item = NSMenuItem()
        let paddingView = MenuPaddingView(height: MenuLayout.verticalPad)
        item.view = paddingView
        menu.addItem(item)
    }

    private func humanizeTokens(_ count: Int) -> String {
        let str: String
        if count < 1000 { str = "\(count)" }
        else if count < 1_000_000 { str = String(format: "%.1fk", Double(count) / 1000.0) }
        else if count < 100_000_000 { str = String(format: "%.1fM", Double(count) / 1_000_000.0) }
        else if count < 1_000_000_000 { str = String(format: "%.0fM", Double(count) / 1_000_000.0) }
        else { str = String(format: "%.2fB", Double(count) / 1_000_000_000.0) }
        return str
    }

    private func humanizeCount(_ count: Int) -> String {
        if count < 10_000 { return "\(count)" }
        return String(format: "%.1fk", Double(count) / 1000.0)
    }

    private func formatCost(_ cost: Double, tokens: Int) -> String {
        if cost == 0 && tokens > 0 { return "Free" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "¥\(formatter.string(from: NSNumber(value: cost))!)"
    }

    private func isCJK(_ char: Character) -> Bool {
        let scalars = char.unicodeScalars
        guard let scalar = scalars.first else { return false }
        if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
        if scalar.value >= 0x3400 && scalar.value <= 0x4DBF { return true }
        if scalar.value >= 0xFF00 && scalar.value <= 0xFFEF { return true }
        if scalar.value == 0x3000 { return true }
        return false
    }
}

extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()
}
