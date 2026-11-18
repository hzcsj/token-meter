import XCTest
@testable import TokenMeter

final class GPT62PricingTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func catalogData() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Resources/pricing.json"))
    }
    private func catalog() throws -> Pricing { try JSONDecoder().decode(Pricing.self, from: catalogData()) }

    func testNewModelsUseOwnRatesAcrossCatalogsAndVariants() throws {
        let pricing = try catalog()
        for (base, factor) in [("gpt-6.2-astra", 4.0), ("gpt-6.2-sol", 1.0)] {
            for suffix in ["", "-2026-11-17", "[1m]", ":latest"] {
                let codex = pricing.findCodexModelPrice(base + suffix, at: date("2026-11-18T00:00:00Z"))
                let general = pricing.findModelPrice(base + suffix)
                XCTAssertEqual(codex.input, 2 * factor)
                XCTAssertEqual(codex.output, 10 * factor)
                XCTAssertEqual(codex.cachedInput, 0.1 * factor)
                XCTAssertEqual(codex.cacheWrite, 2.5 * factor)
                XCTAssertEqual(general.input, codex.input)
                XCTAssertEqual(general.output, codex.output)
                XCTAssertEqual(general.cacheRead, codex.cachedInput)
                XCTAssertEqual(general.cacheWrite5m, codex.cacheWrite)
                XCTAssertEqual(general.cacheWrite1h, codex.cacheWrite)
                XCTAssertEqual(codex.effectiveRates(inputTokens: 272_000).input, 2 * factor)
                let long = codex.effectiveRates(inputTokens: 272_001)
                let generalLong = general.effectiveRates(inputTokens: 272_001)
                XCTAssertEqual(long.input, 4 * factor)
                XCTAssertEqual(long.output, 15 * factor)
                XCTAssertEqual(long.cachedInput, 0.2 * factor)
                XCTAssertEqual(long.cacheWrite, 5 * factor)
                XCTAssertEqual(generalLong.input, long.input)
                XCTAssertEqual(generalLong.output, long.output)
                XCTAssertEqual(generalLong.cacheRead, long.cachedInput)
                XCTAssertEqual(generalLong.cacheWrite5m, long.cacheWrite)
                XCTAssertEqual(generalLong.cacheWrite1h, long.cacheWrite)
            }
        }
    }

    func testUltrafastPromotionEndsAtPacificMidnightAfterReload() throws {
        var pricing = try catalog()
        pricing.priceHistory = pricing.priceHistory?.reversed()
        let restored = try JSONDecoder().decode(Pricing.self, from: JSONEncoder().encode(pricing))
        for model in ["gpt-6.2-astra", "gpt-6.2-sol-2026-11-17"] {
            for (instant, multiplier) in [
                ("2026-11-17T00:00:00Z", 3.0),
                ("2027-03-01T00:00:00Z", 3.0),
                ("2027-03-01T07:59:59Z", 3.0),
                ("2027-03-01T08:00:00Z", 6.0),
                ("2027-03-01T16:00:00+08:00", 6.0)
            ] {
                let price = restored.findCodexModelPrice(model, at: date(instant))
                XCTAssertEqual(price.serviceTierMultiplier("ULTRAFAST"), multiplier)
                XCTAssertEqual(price.serviceTierMultiplier("FAST"), 2)
                XCTAssertEqual(price.serviceTierMultiplier("priority"), 2)
                XCTAssertEqual(price.serviceTierMultiplier("default"), 1)
            }
        }
    }

    func testOmittedTimestampUsesActivePromotionNotFutureListPrice() throws {
        // Keep this test independent of the actual promotion expiry date.
        let source = String(decoding: try catalogData(), as: UTF8.self)
            .replacingOccurrences(of: "2027-03-01T08:00:00Z", with: "9999-03-01T08:00:00Z")
        let pricing = try JSONDecoder().decode(Pricing.self, from: Data(source.utf8))
        XCTAssertEqual(pricing.findCodexModelPrice("gpt-6.2-astra").serviceTierMultiplier("ultrafast"), 3)
        XCTAssertEqual(pricing.findCodexModelPrice("gpt-6.2-sol").serviceTierMultiplier("ultrafast"), 3)
    }

    func testCostsPartitionInputAndApplyDatedSpeedTier() {
        for (model, factor) in [("gpt-6.2-astra", 4.0), ("gpt-6.2-sol", 1.0)] {
            for (tier, multiplier) in [("default", 1.0), ("fast", 2.0), ("priority", 2.0), ("ultrafast", 3.0)] {
                XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
                    cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000, model: model,
                    serviceTier: tier, at: date("2026-11-18T00:00:00Z")), 1.638 * factor * multiplier, accuracy: 0.000001)
                XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 300_000, cachedInput: 100_000,
                    cacheWriteInput: 100_000, output: 10_000, reasoning: 5_000, model: model,
                    serviceTier: tier, at: date("2026-11-18T00:00:00Z")), 7.49 * factor * multiplier, accuracy: 0.000001)
            }
            XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
                cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000, model: model,
                serviceTier: "ultrafast", at: date("2027-03-01T08:00:00Z")), 1.638 * factor * 6, accuracy: 0.000001)
            let usage = UsageRecord.TokenUsage(input: 40_000, output: 10_000,
                cacheWrite5m: 10_000, cacheWrite1h: 10_000, cacheRead: 40_000)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: model),
                           1.638 * factor, accuracy: 0.000001)
        }
    }

    func testExistingGPTModelsKeepTheirPrices() throws {
        let pricing = try catalog()
        for timestamp in ["2026-11-17T00:00:00Z", "2027-03-01T08:00:00Z"] {
            let oldAstra = pricing.findCodexModelPrice("gpt-6-astra", at: date(timestamp))
            XCTAssertEqual(oldAstra.input, 10)
            XCTAssertEqual(oldAstra.cachedInput, 1)
            XCTAssertEqual(oldAstra.serviceTierMultiplier("ultrafast"), 6)
            XCTAssertEqual(pricing.findCodexModelPrice("gpt-6.1-sol", at: date(timestamp)).serviceTierMultiplier("ultrafast"), 6)
            XCTAssertEqual(pricing.findCodexModelPrice("gpt-6-sol", at: date(timestamp)).cachedInput, 0.2)
        }
        XCTAssertEqual(pricing.findCodexModelPrice("gpt-5.6-sol", at: date("2026-08-20T23:59:59Z")).input, 5)
    }

    func testQwen4AndPlusPromotionDoNotRepriceOlderRecordsOrSnapshot() throws {
        let pricing = try catalog()
        let max = pricing.findModelPrice("qwen4-max")
        XCTAssertTrue(max.isCNY)
        XCTAssertEqual(max.input, 10)
        XCTAssertEqual(max.output, 30)
        XCTAssertEqual(max.cacheRead, 0.5)
        XCTAssertEqual(max.cacheWrite5m, 12.5)
        XCTAssertEqual(max.cacheWrite1h, 20)
        let old = pricing.findModelPrice("qwen3.7-plus", at: date("2026-11-17T23:59:59Z"))
        XCTAssertEqual(old.input, 2)
        XCTAssertEqual(old.output, 8)
        XCTAssertNil(old.longContextThreshold)
        let current = pricing.findModelPrice("qwen3.7-plus", at: date("2026-11-18T00:00:00Z"))
        XCTAssertEqual(current.effectiveRates(inputTokens: 256_000).input, 1.6)
        XCTAssertEqual(current.effectiveRates(inputTokens: 256_001).input, 4.8)
        XCTAssertEqual(current.effectiveRates(inputTokens: 256_001).output, 19.2)
        XCTAssertEqual(current.effectiveRates(inputTokens: 256_001).cacheRead, 0.6)
        let fixed = pricing.findModelPrice("qwen3.7-plus-2026-05-26")
        XCTAssertEqual(fixed.input, 2)
        XCTAssertEqual(fixed.output, 8)
        XCTAssertEqual(fixed.effectiveRates(inputTokens: 256_001).input, 6)
        let usage = UsageRecord.TokenUsage(input: 100_000, output: 10_000,
            cacheWrite5m: 10_000, cacheWrite1h: 10_000, cacheRead: 40_000)
        XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: "qwen4-max"), 1.645, accuracy: 0.000001)
    }
}
