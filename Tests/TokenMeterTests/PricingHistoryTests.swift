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

    func testOpus55UsesOwnRatesWithoutChangingOpus5() throws {
        let pricing = try catalog()
        for model in ["claude-opus-5-5", "claude-opus-5-5[1m]", "claude-opus-5-5-20260922"] {
            let price = pricing.findModelPrice(model, at: date("2026-09-22T00:00:00Z"))
            XCTAssertEqual(price.input, 4)
            XCTAssertEqual(price.output, 20)
            XCTAssertEqual(price.cacheRead, 0.2)
            XCTAssertEqual(price.cacheWrite5m, 5)
            XCTAssertEqual(price.cacheWrite1h, 8)
            XCTAssertEqual(price.effectiveRates(inputTokens: 900_000).input, 4)
        }
        for at in ["2026-07-25T00:00:00Z", "2026-09-23T00:00:00Z"] {
            let old = pricing.findModelPrice("claude-opus-5", at: date(at))
            XCTAssertEqual(old.input, 5)
            XCTAssertEqual(old.output, 25)
            XCTAssertEqual(old.cacheRead, 0.5)
        }
        let usage = UsageRecord.TokenUsage(input: 100_000, output: 10_000,
            cacheWrite5m: 20_000, cacheWrite1h: 10_000, cacheRead: 200_000)
        XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: "claude-opus-5-5"), 5.74, accuracy: 0.000_001)
    }

    func testGPT6SolAndLunaInBothCatalogsAndContextBoundaries() throws {
        let pricing = try catalog()
        for (model, input, output, cached, write) in [
            ("gpt-6-sol", 2.0, 10.0, 0.2, 2.5),
            ("gpt-6-luna", 0.1, 0.5, 0.01, 0.125),
        ] {
            for variant in [model, model + "-2026-09-22", model + "[1m]"] {
                let codex = pricing.findCodexModelPrice(variant, at: date("2026-09-22T00:00:00Z"))
                let generic = pricing.findModelPrice(variant)
                XCTAssertEqual(codex.input, input)
                XCTAssertEqual(codex.output, output)
                XCTAssertEqual(codex.cachedInput, cached)
                XCTAssertEqual(codex.cacheWrite, write)
                XCTAssertEqual(generic.input, input)
                XCTAssertEqual(generic.output, output)
                XCTAssertEqual(generic.cacheRead, cached)
                XCTAssertEqual(generic.cacheWrite5m, write)
                XCTAssertEqual(generic.cacheWrite1h, write)
                XCTAssertEqual(codex.effectiveRates(inputTokens: 272_000).input, input)
                XCTAssertEqual(generic.effectiveRates(inputTokens: 272_000).input, input)
                let long = codex.effectiveRates(inputTokens: 272_001)
                XCTAssertEqual(long.input, input * 2)
                XCTAssertEqual(long.output, output * 1.5)
                XCTAssertEqual(long.cachedInput, cached * 2)
                XCTAssertEqual(long.cacheWrite, write * 2)
                XCTAssertEqual(generic.effectiveRates(inputTokens: 272_001).cacheRead, cached * 2)
                XCTAssertEqual(generic.effectiveRates(inputTokens: 272_001).output, output * 1.5)
                XCTAssertEqual(codex.serviceTierMultiplier("FAST"), 2)
                XCTAssertEqual(codex.serviceTierMultiplier("priority"), 2)
                XCTAssertEqual(codex.serviceTierMultiplier("default"), 1)
            }
        }
    }

    func testNewGPT6CostsIncludeAllTokenPartitions() {
        for (model, short, long) in [("gpt-6-sol", 3.332, 7.63), ("gpt-6-luna", 0.1666, 0.3815)] {
            XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
                cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000,
                model: model, serviceTier: "fast"), short, accuracy: 0.000_001)
            XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 300_000, cachedInput: 100_000,
                cacheWriteInput: 100_000, output: 10_000, reasoning: 5_000,
                model: model, serviceTier: "default"), long, accuracy: 0.000_001)
        }
    }

    func testPriceChangesInvalidateCostCache() {
        let original = Data("old catalog".utf8)
        XCTAssertEqual(PricingEngine.catalogFingerprint(original), PricingEngine.catalogFingerprint(original))
        XCTAssertNotEqual(PricingEngine.catalogFingerprint(original), PricingEngine.catalogFingerprint(Data("new catalog".utf8)))
    }

    func testGPT61SolCostsUseOwnCachePriceAcrossCatalogsAndVariants() {
        for model in ["gpt-6.1-sol", "gpt-6.1-sol-2026-09-29", "gpt-6.1-sol[1m]"] {
            let timestamp = date("2026-09-29T12:00:00Z")
            for (tier, expected) in [("default", 1.638), ("fast", 3.276), ("PRIORITY", 3.276)] {
                let cost = PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
                    cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000,
                    model: model, serviceTier: tier, at: timestamp)
                XCTAssertEqual(cost, expected, accuracy: 0.000_001, "\(model) \(tier)")
            }
            let usage = UsageRecord.TokenUsage(input: 40_000, output: 10_000,
                cacheWrite5m: 10_000, cacheWrite1h: 10_000, cacheRead: 40_000)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: model, at: timestamp),
                           1.638, accuracy: 0.000_001, model)
        }
        let oldCost = PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
            cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000,
            model: "gpt-6-sol", serviceTier: "default", at: date("2026-09-29T12:00:00Z"))
        XCTAssertEqual(oldCost, 1.666, accuracy: 0.000_001)
    }

    func testGPT61SolLongContextCostsIncludeCachedAndWrittenInput() {
        for (input, expected) in [(272_000, 0.1904), (272_001, 0.3808014)] {
            let codex = PricingEngine.shared.calculateCodexCNY(input: input, cachedInput: input,
                cacheWriteInput: 0, output: 0, reasoning: 0,
                model: "gpt-6.1-sol", serviceTier: "default")
            let usage = UsageRecord.TokenUsage(input: 0, output: 0, cacheWrite5m: 0,
                cacheWrite1h: 0, cacheRead: input)
            XCTAssertEqual(codex, expected, accuracy: 0.000_001)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: "gpt-6.1-sol"),
                           expected, accuracy: 0.000_001)
        }
        let usage = UsageRecord.TokenUsage(input: 100_000, output: 10_000,
            cacheWrite5m: 50_000, cacheWrite1h: 50_000, cacheRead: 100_000)
        XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: "gpt-6.1-sol"),
                       7.49, accuracy: 0.000_001)
        for (tier, expected) in [("default", 7.49), ("fast", 14.98)] {
            XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 300_000, cachedInput: 100_000,
                cacheWriteInput: 100_000, output: 10_000, reasoning: 5_000,
                model: "gpt-6.1-sol", serviceTier: tier), expected, accuracy: 0.000_001)
        }
    }
}
