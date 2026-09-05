import XCTest
@testable import TokenMeter

final class PricingHistoryTests: XCTestCase {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func catalog() throws -> Pricing {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pricing.json")
        return try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
    }

    func testOfficialPriceCutoffsPreserveOldRates() throws {
        let pricing = try catalog()
        for model in ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-sol-2026-07-09"] {
            XCTAssertEqual(pricing.findCodexModelPrice(model, at: date("2026-08-20T23:59:59Z")).input, 5)
            XCTAssertEqual(pricing.findCodexModelPrice(model, at: date("2026-08-21T00:00:00Z")).input, 4)
            XCTAssertEqual(pricing.findCodexModelPrice(model, at: date("2026-08-21T08:00:00+08:00")).output, 20)
        }
        for (model, old, current) in [("gpt-5.6-terra", 2.5, 2.0), ("gpt-5.6-luna", 1.0, 0.2)] {
            XCTAssertEqual(pricing.findCodexModelPrice(model, at: date("2026-07-29T23:59:59Z")).input, old)
            XCTAssertEqual(pricing.findCodexModelPrice(model, at: date("2026-07-30T00:00:00Z")).input, current)
        }
    }

    func testHistoricalServiceTiersAndContextRates() throws {
        let pricing = try catalog()
        let old = pricing.findCodexModelPrice("gpt-5.6-sol", at: date("2026-07-29T23:59:59Z"))
        let middle = pricing.findCodexModelPrice("gpt-5.6-sol", at: date("2026-07-30T00:00:00Z"))
        let current = pricing.findCodexModelPrice("gpt-5.6-sol")
        XCTAssertEqual(old.serviceTierMultiplier("fast"), 2.5)
        XCTAssertEqual(middle.serviceTierMultiplier("fast"), 2)
        XCTAssertEqual(middle.serviceTierMultiplier("priority"), 2)
        XCTAssertEqual(middle.effectiveRates(inputTokens: 272_001).cacheWrite, 12.5)
        XCTAssertEqual(current.effectiveRates(inputTokens: 272_000).input, 4)
        XCTAssertEqual(current.effectiveRates(inputTokens: 272_001).cacheWrite, 10)
        XCTAssertEqual(current.effectiveRates(inputTokens: 272_001).output, 30)
    }

    func testHistoryIsOrderIndependentAndSurvivesReload() throws {
        var pricing = try catalog()
        pricing.priceHistory = pricing.priceHistory?.reversed()
        let restored = try JSONDecoder().decode(Pricing.self, from: JSONEncoder().encode(pricing))
        XCTAssertEqual(restored.findCodexModelPrice("gpt-5.6-sol", at: date("2026-07-25T00:00:00Z")).serviceTierMultiplier("fast"), 2.5)
        XCTAssertEqual(restored.findCodexModelPrice("gpt-5.6-sol", at: date("2026-08-01T00:00:00Z")).serviceTierMultiplier("fast"), 2)
    }

    func testNewModelAndSnapshotIDsDoNotUseOldFallbackPrices() throws {
        let pricing = try catalog()
        for model in ["claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5-1[1m]", "claude-fable-5-1-20260901"] {
            let price = pricing.findModelPrice(model, at: date("2026-09-01T00:00:00Z"))
            XCTAssertEqual(price.cacheRead, 0.25)
            XCTAssertEqual(price.cacheWrite5m, 12.5)
            XCTAssertEqual(price.cacheWrite1h, 20)
        }
        XCTAssertEqual(pricing.findModelPrice("claude-fable-5").cacheRead, 1)
        XCTAssertEqual(pricing.findModelPrice("claude-sonnet-5").input, 2)
        let astra = pricing.findCodexModelPrice("gpt-6-astra-2026-09-03", at: date("2026-09-03T00:00:00Z"))
        XCTAssertEqual(astra.effectiveRates(inputTokens: 272_000).input, 10)
        XCTAssertEqual(astra.effectiveRates(inputTokens: 272_001).input, 20)
        XCTAssertEqual(astra.effectiveRates(inputTokens: 272_001).cachedInput, 2)
        XCTAssertEqual(astra.effectiveRates(inputTokens: 272_001).cacheWrite, 25)
        XCTAssertEqual(astra.effectiveRates(inputTokens: 272_001).output, 75)
        XCTAssertEqual(astra.serviceTierMultiplier("FAST"), 2)
        XCTAssertEqual(astra.serviceTierMultiplier("priority"), 2)
    }

    func testHistoricalCostsUseEventTimeNotRebuildTime() {
        func cost(_ at: String) -> Double {
            PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 0,
                cacheWriteInput: 100_000, output: 10_000, reasoning: 5_000,
                model: "gpt-5.6-sol", serviceTier: "fast", at: date(at))
        }
        XCTAssertEqual(cost("2026-07-29T23:59:59Z"), 16.1875, accuracy: 0.000_001)
        XCTAssertEqual(cost("2026-07-30T00:00:00Z"), 12.95, accuracy: 0.000_001)
        XCTAssertEqual(cost("2026-08-21T00:00:00Z"), 9.8, accuracy: 0.000_001)
    }

    func testNewModelCostsIncludeCachePartitionsAndNotReasoningTwice() {
        let short = PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
            cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000,
            model: "gpt-6-astra", serviceTier: "fast")
        let long = PricingEngine.shared.calculateCodexCNY(input: 300_000, cachedInput: 100_000,
            cacheWriteInput: 100_000, output: 10_000, reasoning: 5_000,
            model: "gpt-6-astra", serviceTier: "default")
        XCTAssertEqual(short, 16.66, accuracy: 0.000_001)
        XCTAssertEqual(long, 38.15, accuracy: 0.000_001)
        let usage = UsageRecord.TokenUsage(input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 1_000_000)
        XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: "claude-fable-5-1"), 1.75, accuracy: 0.000_001)
    }

    func testPriceChangesInvalidateCostCache() {
        let original = Data("old catalog".utf8)
        XCTAssertEqual(PricingEngine.catalogFingerprint(original), PricingEngine.catalogFingerprint(original))
        XCTAssertNotEqual(PricingEngine.catalogFingerprint(original), PricingEngine.catalogFingerprint(Data("new catalog".utf8)))
    }
}
