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






    private func daily(_ date: String, tokens: Int, cost: Double, messages: Int) -> DailyUsage {
        DailyUsage(date: date, tokens: tokens, costCNY: cost, messageCount: messages)
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
