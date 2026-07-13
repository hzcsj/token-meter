import AppKit
import Foundation
import SQLite3
import XCTest
@testable import TokenMeter

final class OpenCodeUsageScannerTests: XCTestCase {
    func testAssistantTokenFieldsMapIncludingReasoning() throws {
        let fixture = try makeDatabase()
        defer { fixture.close() }

        try insert(
            into: fixture.db,
            id: "assistant-1",
            milliseconds: 1_752_422_400_000,
            data: messageData(
                model: "Qwen3.7-Max-DogFooding[1M]",
                input: 10,
                output: 20,
                reasoning: 3,
                cacheRead: 4,
                cacheWrite: 5
            )
        )
        try insert(
            into: fixture.db,
            id: "user-1",
            milliseconds: 1_752_422_400_001,
            data: messageData(model: "qwen3.7-max", role: "user", input: 999)
        )
        try insert(
            into: fixture.db,
            id: "assistant-1",
            milliseconds: 1_752_422_400_002,
            data: messageData(model: "qwen3.7-max", input: 999)
        )

        let records = OpenCodeUsageScanner(databaseURL: fixture.url).scanRecords()
        let record = try XCTUnwrap(records.first)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.source, .opencode)
        XCTAssertEqual(record.tokens.input, 10)
        XCTAssertEqual(record.tokens.output, 23)
        XCTAssertEqual(record.tokens.cacheRead, 4)
        XCTAssertEqual(record.tokens.cacheWrite5m, 5)
        XCTAssertEqual(record.tokens.cacheWrite1h, 0)
        XCTAssertEqual(record.tokens.total, 42)
    }

    func testDogFoodingVariantsCountTokensAndMessagesButRemainFree() throws {
        let fixture = try makeDatabase()
        defer { fixture.close() }

        let models = [
            "Qwen3.7-Max-DogFooding",
            "Qwen3.7-Max-DogFooding[1M]",
            "qwen37-max-dogfooding-1m",
            "QWEN3.7-MAX-DOGFOODING[1m]"
        ]

        for (index, model) in models.enumerated() {
            try insert(
                into: fixture.db,
                id: "dogfood-\(index)",
                milliseconds: 1_752_422_400_000 + Int64(index),
                data: messageData(model: model, input: 10, output: 20)
            )
        }

        let scanner = OpenCodeUsageScanner(databaseURL: fixture.url)
        let records = scanner.scanRecords()
        let summary = try XCTUnwrap(scanner.scan())

        XCTAssertEqual(records.count, models.count)
        XCTAssertTrue(records.allSatisfy { $0.costCNY == 0 })
        XCTAssertEqual(summary.allTimeTotal.tokens, 120)
        XCTAssertEqual(summary.allTimeTotal.messageCount, models.count)
        XCTAssertEqual(summary.allTimeTotal.costCNY, 0)
    }

    func testNonDogFoodingModelUsesStandardPricing() throws {
        let fixture = try makeDatabase()
        defer { fixture.close() }

        try insert(
            into: fixture.db,
            id: "paid-1",
            milliseconds: 1_752_422_400_000,
            data: messageData(
                model: "qwen3.7-max",
                input: 1_000_000,
                output: 1_000_000,
                reasoning: 1_000_000,
                cacheRead: 1_000_000,
                cacheWrite: 1_000_000
            )
        )

        let record = try XCTUnwrap(OpenCodeUsageScanner(databaseURL: fixture.url).scanRecords().first)

        XCTAssertEqual(record.tokens.total, 5_000_000)
        XCTAssertEqual(record.costCNY, 100.2, accuracy: 0.000_001)
    }

    func testAsiaShanghaiAggregationAndMalformedJSONSkip() throws {
        let fixture = try makeDatabase()
        defer { fixture.close() }

        try insert(
            into: fixture.db,
            id: "before-midnight",
            milliseconds: milliseconds("2026-07-12T15:59:59Z"),
            data: messageData(model: "Qwen3.7-Max-DogFooding", input: 1)
        )
        try insert(
            into: fixture.db,
            id: "after-midnight",
            milliseconds: milliseconds("2026-07-12T16:00:00Z"),
            data: messageData(model: "Qwen3.7-Max-DogFooding", input: 2)
        )
        try insert(
            into: fixture.db,
            id: "broken",
            milliseconds: milliseconds("2026-07-12T16:00:01Z"),
            data: "{not-json"
        )

        let summary = try XCTUnwrap(OpenCodeUsageScanner(databaseURL: fixture.url).scan())

        XCTAssertEqual(summary.byDay.map(\.date), ["2026-07-13", "2026-07-12"])
        XCTAssertEqual(summary.byDay.map(\.tokens), [2, 1])
        XCTAssertEqual(summary.allTimeTotal.messageCount, 2)
    }

    func testMissingDatabaseAndSchemaMismatchReturnNil() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.db")
        XCTAssertNil(OpenCodeUsageScanner(databaseURL: missingURL).scan())

        let fixture = try makeDatabase(schema: "CREATE TABLE other (id TEXT)")
        defer { fixture.close() }
        XCTAssertNil(OpenCodeUsageScanner(databaseURL: fixture.url).scan())
    }

    func testReadOnlyScannerSeesUncheckpointedWALMessage() throws {
        let fixture = try makeDatabase(wal: true)
        defer { fixture.close() }

        try execute(fixture.db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        try insert(
            into: fixture.db,
            id: "wal-message",
            milliseconds: 1_752_422_400_000,
            data: messageData(model: "Qwen3.7-Max-DogFooding", input: 7, reasoning: 5)
        )

        let walPath = fixture.url.path + "-wal"
        XCTAssertGreaterThan(try fileSize(walPath), 0)

        let summary = try XCTUnwrap(OpenCodeUsageScanner(databaseURL: fixture.url).scan())
        XCTAssertEqual(summary.allTimeTotal.tokens, 12)
        XCTAssertEqual(summary.allTimeTotal.messageCount, 1)
    }

    func testThreeSourceMergeAddsSameDayWithoutOverwritingOtherDays() throws {
        let builder = MenuBuilder()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T04:00:00Z"))
        let claude = summary(days: [daily("2026-07-13", tokens: 10, cost: 1, messages: 1)])
        let codex = summary(days: [daily("2026-07-13", tokens: 20, cost: 2, messages: 2)])
        let openCode = summary(days: [
            daily("2026-07-13", tokens: 30, cost: 3, messages: 3),
            daily("2026-07-12", tokens: 40, cost: 4, messages: 4)
        ])

        let merged = try XCTUnwrap(builder.mergeUsage([claude, codex, openCode], now: now))

        XCTAssertEqual(merged.byDay.count, 2)
        XCTAssertEqual(merged.byDay[0], daily("2026-07-13", tokens: 60, cost: 6, messages: 6))
        XCTAssertEqual(merged.byDay[1], daily("2026-07-12", tokens: 40, cost: 4, messages: 4))
        XCTAssertEqual(merged.weekTotal.tokens, 100)
        XCTAssertEqual(merged.allTimeTotal.messageCount, 10)
    }

    func testLocalUsageRowsExposeFieldLevelSourceTooltips() throws {
        let today = DateFormatter.yyyyMMdd.string(from: Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let oldDate = DateFormatter.yyyyMMdd.string(
            from: calendar.date(byAdding: .day, value: -40, to: Date())!
        )
        let claude = summary(days: [
            daily(today, tokens: 100, cost: 1, messages: 1),
            daily(oldDate, tokens: 50, cost: 2, messages: 2)
        ])
        let openCode = summary(days: [daily(today, tokens: 300, cost: 0, messages: 3)])

        let menu = MenuBuilder().build(
            claudeUsage: claude,
            codexUsage: nil,
            openCodeUsage: openCode,
            codexQuota: nil
        )
        let rows = menu.items.compactMap { $0.view as? MenuUsageRowView }

        XCTAssertEqual(rows.count, 5)
        for row in rows {
            XCTAssertFalse(field("usage.label", in: row) is MenuTooltipTextField)
            for identifier in ["usage.tokens", "usage.count", "usage.cost"] {
                let tooltipField = field(identifier, in: row) as? MenuTooltipTextField
                XCTAssertNil(tooltipField?.toolTip)
                XCTAssertEqual(tooltipField?.tooltipRows.count, 4)
            }
        }

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(tooltipRows("usage.tokens", in: row), [
            MenuTooltipRow(name: "Claude Code", value: "100 Tok"),
            MenuTooltipRow(name: "Codex", value: "0 Tok"),
            MenuTooltipRow(name: "OpenCode", value: "300 Tok"),
            MenuTooltipRow(name: "合计", value: "400 Tok")
        ])
        XCTAssertEqual(tooltipRows("usage.count", in: row), [
            MenuTooltipRow(name: "Claude Code", value: "1次"),
            MenuTooltipRow(name: "Codex", value: "0次"),
            MenuTooltipRow(name: "OpenCode", value: "3次"),
            MenuTooltipRow(name: "合计", value: "4次")
        ])
        XCTAssertEqual(tooltipRows("usage.cost", in: row), [
            MenuTooltipRow(name: "Claude Code", value: "¥1.00"),
            MenuTooltipRow(name: "Codex", value: "¥0.00"),
            MenuTooltipRow(name: "OpenCode", value: "Free"),
            MenuTooltipRow(name: "合计", value: "¥1.00")
        ])

        let allTimeRow = try XCTUnwrap(rows.last)
        XCTAssertEqual(tooltipRows("usage.tokens", in: allTimeRow), [
            MenuTooltipRow(name: "Claude Code", value: "150 Tok"),
            MenuTooltipRow(name: "Codex", value: "0 Tok"),
            MenuTooltipRow(name: "OpenCode", value: "300 Tok"),
            MenuTooltipRow(name: "合计", value: "450 Tok")
        ])
        XCTAssertEqual(tooltipRows("usage.count", in: allTimeRow), [
            MenuTooltipRow(name: "Claude Code", value: "3次"),
            MenuTooltipRow(name: "Codex", value: "0次"),
            MenuTooltipRow(name: "OpenCode", value: "3次"),
            MenuTooltipRow(name: "合计", value: "6次")
        ])
        XCTAssertEqual(tooltipRows("usage.cost", in: allTimeRow), [
            MenuTooltipRow(name: "Claude Code", value: "¥3.00"),
            MenuTooltipRow(name: "Codex", value: "¥0.00"),
            MenuTooltipRow(name: "OpenCode", value: "Free"),
            MenuTooltipRow(name: "合计", value: "¥3.00")
        ])
    }

    func testSourceTooltipViewUsesRoundedShadowedAlignedColumns() throws {
        let tooltipRows = [
            MenuTooltipRow(name: "Claude Code", value: "100 Tok"),
            MenuTooltipRow(name: "Codex", value: "0 Tok"),
            MenuTooltipRow(name: "OpenCode", value: "300 Tok"),
            MenuTooltipRow(name: "合计", value: "400 Tok")
        ]
        let view = MenuSourceTooltipView(rows: tooltipRows)
        let layer = try XCTUnwrap(view.layer)

        XCTAssertEqual(layer.cornerRadius, 8, accuracy: 0.001)
        XCTAssertGreaterThan(layer.borderWidth, 0)
        XCTAssertGreaterThan(layer.shadowOpacity, 0)
        XCTAssertGreaterThan(layer.shadowRadius, 0)
        XCTAssertFalse(layer.masksToBounds)
        XCTAssertEqual(view.nameFields.map(\.stringValue), tooltipRows.map(\.name))
        XCTAssertEqual(view.valueFields.map(\.stringValue), tooltipRows.map(\.value))
        XCTAssertTrue(view.nameFields.allSatisfy { $0.alignment == .left })
        XCTAssertTrue(view.valueFields.allSatisfy { $0.alignment == .right })
        XCTAssertNotNil(view.separatorView)

        let nameX = try XCTUnwrap(view.nameFields.first?.frame.minX)
        XCTAssertTrue(view.nameFields.allSatisfy { abs($0.frame.minX - nameX) < 0.001 })
        let valueRight = try XCTUnwrap(view.valueFields.first?.frame.maxX)
        XCTAssertTrue(view.valueFields.allSatisfy { abs($0.frame.maxX - valueRight) < 0.001 })

        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testTooltipRenderedValuesShareExactRightmostPixel() throws {
        let names = ["Claude Code", "Codex", "OpenCode", "合计"]
        let valueSets = [
            ["152M Tok", "1.52B Tok", "55.9M Tok", "1.73B Tok"],
            ["467次", "10.6k次", "335次", "11.4k次"],
            ["¥1.23", "¥912.40", "Free", "¥913.63"]
        ]

        for values in valueSets {
            let rows = zip(names, values).map {
                MenuTooltipRow(name: $0.0, value: $0.1)
            }
            let edges = try renderedValueRightEdges(in: MenuSourceTooltipView(rows: rows))
            XCTAssertEqual(Set(edges).count, 1, "values=\(values), edges=\(edges)")
        }
    }

    func testTooltipHoverFiresInsideMenuEventTrackingRunLoop() throws {
        _ = NSApplication.shared
        let tooltipRows = [
            MenuTooltipRow(name: "Claude Code", value: "100 Tok"),
            MenuTooltipRow(name: "合计", value: "100 Tok")
        ]
        let mouse = NSEvent.mouseLocation
        let window = NSWindow(
            contentRect: NSRect(x: mouse.x - 40, y: mouse.y - 20, width: 80, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let field = MenuTooltipTextField(text: "100 Tok", tooltipRows: tooltipRows)
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        window.contentView = field
        window.orderFrontRegardless()

        let presenter = MenuTooltipPresenter.shared
        presenter.register(field)
        defer {
            presenter.hide()
            presenter.unregister(field)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
            window.orderOut(nil)
        }

        XCTAssertTrue(presenter.registeredField(at: mouse) === field)
        presenter.show(rows: tooltipRows, relativeTo: field)
        let deadline = Date().addingTimeInterval(0.5)
        while !presenter.isTooltipVisible && Date() < deadline {
            _ = RunLoop.main.run(
                mode: .eventTracking,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        }
        XCTAssertTrue(presenter.isTooltipVisible)
    }

    func testTooltipStaysVisibleInsideRealMenuTrackingSession() {
        _ = NSApplication.shared
        let rows = [
            MenuTooltipRow(name: "Claude Code", value: "100 Tok"),
            MenuTooltipRow(name: "合计", value: "100 Tok")
        ]
        let menu = NSMenu()
        let item = NSMenuItem()
        let source = MenuTooltipTextField(text: "100 Tok", tooltipRows: rows)
        source.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        item.view = source
        menu.addItem(item)

        let presenter = MenuTooltipPresenter.shared
        var tooltipWasVisible = false
        var menuWasStillVisible = false
        let inspectTimer = Timer(timeInterval: 0.4, repeats: false) { _ in
            tooltipWasVisible = presenter.isTooltipVisible
            menuWasStillVisible = source.window?.isVisible == true
            menu.cancelTracking()
        }
        RunLoop.main.add(inspectTimer, forMode: .eventTracking)

        let mouse = NSEvent.mouseLocation
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: mouse.x, y: mouse.y + source.frame.height / 2),
            in: nil
        )
        presenter.hide()

        XCTAssertTrue(tooltipWasVisible)
        XCTAssertTrue(menuWasStillVisible)
    }

    private func daily(_ date: String, tokens: Int, cost: Double, messages: Int) -> DailyUsage {
        DailyUsage(date: date, tokens: tokens, costCNY: cost, messageCount: messages)
    }

    private func renderedValueRightEdges(in view: MenuSourceTooltipView) throws -> [Int] {
        view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.displayIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width

        return try view.valueFields.map { field in
            let minX = max(0, Int(floor(field.frame.minX * scale)))
            let maxX = min(bitmap.pixelsWide - 1, Int(ceil(field.frame.maxX * scale)) - 1)
            let minY = max(0, Int(floor((view.bounds.maxY - field.frame.maxY) * scale)))
            let maxY = min(
                bitmap.pixelsHigh - 1,
                Int(ceil((view.bounds.maxY - field.frame.minY) * scale)) - 1
            )
            var rightmost: Int?
            for y in minY...maxY {
                for x in minX...maxX {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { continue }
                    let luminance = color.redComponent * 0.2126
                        + color.greenComponent * 0.7152
                        + color.blueComponent * 0.0722
                    if luminance > 0.55 {
                        rightmost = max(rightmost ?? x, x)
                    }
                }
            }
            return try XCTUnwrap(rightmost, "No rendered glyph pixels for \(field.stringValue)")
        }
    }

    private func summary(days: [DailyUsage]) -> UsageSummary {
        let total = DailyUsage(
            date: "total",
            tokens: days.reduce(0) { $0 + $1.tokens },
            costCNY: days.reduce(0.0) { $0 + $1.costCNY },
            messageCount: days.reduce(0) { $0 + $1.messageCount }
        )
        return UsageSummary(byDay: days, weekTotal: total, monthTotal: total, allTimeTotal: total)
    }

    private func field(_ identifier: String, in row: MenuUsageRowView) -> NSTextField? {
        row.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == identifier }
    }

    private func tooltipRows(_ identifier: String, in row: MenuUsageRowView) -> [MenuTooltipRow]? {
        (field(identifier, in: row) as? MenuTooltipTextField)?.tooltipRows
    }

    private func messageData(
        model: String,
        role: String = "assistant",
        input: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> String {
        """
        {"role":"\(role)","modelID":"\(model)","providerID":"test-provider","tokens":{"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}},"cost":999}
        """
    }

    private func milliseconds(_ iso8601: String) -> Int64 {
        let date = ISO8601DateFormatter().date(from: iso8601)!
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func makeDatabase(
        schema: String = "CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT)",
        wal: Bool = false
    ) throws -> DatabaseFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteTestError.open
        }

        if wal {
            try execute(db, sql: "PRAGMA journal_mode=WAL")
            try execute(db, sql: "PRAGMA wal_autocheckpoint=0")
        }
        try execute(db, sql: schema)

        return DatabaseFixture(url: url, db: db, directory: directory)
    }

    private func insert(into db: OpaquePointer, id: String, milliseconds: Int64, data: String) throws {
        let escapedId = id.replacingOccurrences(of: "'", with: "''")
        let escapedData = data.replacingOccurrences(of: "'", with: "''")
        try execute(
            db,
            sql: "INSERT INTO message (id, time_created, data) VALUES ('\(escapedId)', \(milliseconds), '\(escapedData)')"
        )
    }

    private func execute(_ db: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteTestError.execute
        }
    }

    private func fileSize(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return attributes[.size] as? UInt64 ?? 0
    }
}

private struct DatabaseFixture {
    let url: URL
    let db: OpaquePointer
    let directory: URL

    func close() {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum SQLiteTestError: Error {
    case open
    case execute
}
