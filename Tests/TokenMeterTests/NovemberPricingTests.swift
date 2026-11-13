import XCTest
@testable import TokenMeter

final class NovemberPricingTests: XCTestCase {
    private func catalog() throws -> Pricing {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: root.appendingPathComponent("Resources/pricing.json")))
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testFableAndMythos52DoNotReprice51() throws {
        let pricing = try catalog()
        for family in ["fable", "mythos"] {
            for suffix in ["", "[1m]", "-20261112"] {
                let price = pricing.findModelPrice("claude-\(family)-5-2\(suffix)", at: date("2026-11-13T00:00:00Z"))
                XCTAssertEqual(price.input, 8)
                XCTAssertEqual(price.output, 40)
                XCTAssertEqual(price.cacheRead, 0.2)
                XCTAssertEqual(price.cacheWrite5m, 10)
                XCTAssertEqual(price.cacheWrite1h, 16)
                XCTAssertEqual(price.effectiveRates(inputTokens: 1_000_000).input, 8)
            }
            let old = pricing.findModelPrice("claude-\(family)-5-1")
            XCTAssertEqual(old.input, 10)
            XCTAssertEqual(old.output, 50)
            XCTAssertEqual(old.cacheRead, 0.25)
        }
    }

    func testCarbonPromotionAndHydrogenRates() throws {
        let pricing = try catalog()
        let before = pricing.findModelPrice("gemini-4-carbon", at: date("2026-11-30T23:59:59Z"))
        let after = pricing.findModelPrice("gemini-4-carbon", at: date("2026-12-01T00:00:00Z"))
        XCTAssertEqual(before.input, 2)
        XCTAssertEqual(before.output, 10)
        XCTAssertEqual(before.cacheRead, 0.1)
        XCTAssertEqual(after.input, 4)
        XCTAssertEqual(after.output, 20)
        XCTAssertEqual(after.cacheRead, 0.2)
        let hydrogen = pricing.findModelPrice("gemini-4-hydrogen")
        XCTAssertEqual(hydrogen.input, 1.5)
        XCTAssertEqual(hydrogen.output, 7.5)
        XCTAssertEqual(hydrogen.cacheRead, 0.075)
    }

    func testGemini25ProMigrationPreservesCompleteHistoricalEntry() throws {
        let pricing = try catalog()
        let old = pricing.findModelPrice("gemini-2.5-pro", at: date("2026-11-30T23:59:59Z"))
        XCTAssertEqual(old.input, 1.25)
        XCTAssertEqual(old.output, 10)
        XCTAssertEqual(old.cacheRead, 0.125)
        XCTAssertEqual(old.effectiveRates(inputTokens: 200_001).input, 2.5)
        XCTAssertEqual(old.effectiveRates(inputTokens: 200_001).output, 15)
        let december = pricing.findModelPrice("gemini-2.5-pro", at: date("2026-12-01T00:00:00Z"))
        XCTAssertEqual(december.input, 0.75)
        XCTAssertEqual(december.output, 3.75)
        XCTAssertEqual(december.cacheRead, 0.075)
        XCTAssertEqual(december.effectiveRates(inputTokens: 200_001).input, 0.75)
        let january = pricing.findModelPrice("gemini-2.5-pro", at: date("2027-01-01T00:00:00Z"))
        XCTAssertEqual(january.input, 1.5)
        XCTAssertEqual(january.output, 7.5)
        XCTAssertEqual(january.cacheRead, 0.15)
    }
}
