import XCTest
@testable import TokenMeter

final class GPT61TerraPricingTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func catalog() throws -> Pricing {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pricing.json")
        return try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
    }

    private let variants = ["gpt-6.1-terra", "gpt-6.1-terra-2026-10-26", "gpt-6.1-terra[1m]"]

    func testOwnRatesInBothCatalogsAtLaunchAndAfterReload() throws {
        var pricing = try catalog()
        pricing.priceHistory = pricing.priceHistory?.reversed()
        let restored = try JSONDecoder().decode(Pricing.self, from: JSONEncoder().encode(pricing))
        for model in variants {
            for timestamp in ["2026-10-26T00:00:00Z", "2026-11-06T00:00:00Z"] {
                let codex = restored.findCodexModelPrice(model, at: date(timestamp))
                let generic = restored.findModelPrice(model, at: date(timestamp))
                XCTAssertEqual(codex.input, 1)
                XCTAssertEqual(codex.output, 5)
                XCTAssertEqual(codex.cachedInput, 0.05)
                XCTAssertEqual(codex.cacheWrite, 1.25)
                XCTAssertEqual(generic.input, codex.input)
                XCTAssertEqual(generic.output, codex.output)
                XCTAssertEqual(generic.cacheRead, codex.cachedInput)
                XCTAssertEqual(generic.cacheWrite5m, codex.cacheWrite)
                XCTAssertEqual(generic.cacheWrite1h, codex.cacheWrite)
                XCTAssertFalse(generic.isCNY)
                XCTAssertEqual(codex.serviceTierMultiplier("FAST"), 2)
                XCTAssertEqual(codex.serviceTierMultiplier("priority"), 2)
                XCTAssertEqual(codex.serviceTierMultiplier("default"), 1)
                XCTAssertEqual(codex.serviceTierMultiplier(""), 1)
                XCTAssertNil(codex.serviceTierMultipliers?["ultrafast"])
            }
        }
    }

    func test272KBoundaryAcrossCatalogs() throws {
        let pricing = try catalog()
        for model in variants {
            let codex = pricing.findCodexModelPrice(model)
            let generic = pricing.findModelPrice(model)
            XCTAssertEqual(codex.effectiveRates(inputTokens: 272_000).input, 1)
            XCTAssertEqual(generic.effectiveRates(inputTokens: 272_000).output, 5)
            let long = codex.effectiveRates(inputTokens: 272_001)
            let generalLong = generic.effectiveRates(inputTokens: 272_001)
            XCTAssertEqual(long.input, 2)
            XCTAssertEqual(long.output, 7.5)
            XCTAssertEqual(long.cachedInput, 0.1)
            XCTAssertEqual(long.cacheWrite, 2.5)
            XCTAssertEqual(generalLong.input, long.input)
            XCTAssertEqual(generalLong.output, long.output)
            XCTAssertEqual(generalLong.cacheRead, long.cachedInput)
            XCTAssertEqual(generalLong.cacheWrite5m, long.cacheWrite)
            XCTAssertEqual(generalLong.cacheWrite1h, long.cacheWrite)
        }
    }

    func testCostsPartitionInputAndDoNotDoubleCountReasoning() {
        let timestamp = date("2026-10-26T12:00:00Z")
        for model in variants {
            for (tier, short, long) in [("default", 0.819, 3.745), ("fast", 1.638, 7.49),
                                       ("PRIORITY", 1.638, 7.49)] {
                XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 100_000, cachedInput: 40_000,
                    cacheWriteInput: 20_000, output: 10_000, reasoning: 5_000, model: model,
                    serviceTier: tier, at: timestamp), short, accuracy: 0.000001)
                XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: 300_000, cachedInput: 100_000,
                    cacheWriteInput: 100_000, output: 10_000, reasoning: 5_000, model: model,
                    serviceTier: tier, at: timestamp), long, accuracy: 0.000001)
            }
            let short = UsageRecord.TokenUsage(input: 40_000, output: 10_000,
                cacheWrite5m: 10_000, cacheWrite1h: 10_000, cacheRead: 40_000)
            let long = UsageRecord.TokenUsage(input: 100_000, output: 10_000,
                cacheWrite5m: 50_000, cacheWrite1h: 50_000, cacheRead: 100_000)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: short, model: model, at: timestamp),
                           0.819, accuracy: 0.000001)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: long, model: model, at: timestamp),
                           3.745, accuracy: 0.000001)
        }
    }

    func testCachedAndWrittenInputCountTowardLongContextButOutputDoesNot() {
        for (input, readCost, writeCost) in [(272_000, 0.0952, 2.38), (272_001, 0.1904007, 4.7600175)] {
            XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: input, cachedInput: input,
                cacheWriteInput: 0, output: 0, reasoning: 0, model: variants[0], serviceTier: "default"),
                readCost, accuracy: 0.000001)
            let readUsage = UsageRecord.TokenUsage(input: 0, output: 0,
                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: input)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: readUsage, model: variants[0]),
                           readCost, accuracy: 0.000001)
            XCTAssertEqual(PricingEngine.shared.calculateCodexCNY(input: input, cachedInput: 0,
                cacheWriteInput: input, output: 0, reasoning: 0, model: variants[0], serviceTier: "default"),
                writeCost, accuracy: 0.000001)
            let writtenUsage = UsageRecord.TokenUsage(input: 0, output: 0,
                cacheWrite5m: 100_000, cacheWrite1h: input - 100_000, cacheRead: 0)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: writtenUsage, model: variants[0]),
                           writeCost, accuracy: 0.000001)
        }
        let outputUsage = UsageRecord.TokenUsage(input: 0, output: 128_000,
            cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 272_000)
        XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: outputUsage, model: variants[0]),
                       4.5752, accuracy: 0.000001)
    }

    func testExistingTerraAndSolKeepTheirHistoricalRates() throws {
        let pricing = try catalog()
        for (timestamp, oldTerraInput, oldSolInput) in [
            ("2026-07-29T23:59:59Z", 2.5, 5.0),
            ("2026-08-21T00:00:00Z", 2.0, 4.0),
            ("2026-11-06T00:00:00Z", 2.0, 4.0),
        ] {
            XCTAssertEqual(pricing.findCodexModelPrice("gpt-5.6-terra", at: date(timestamp)).input, oldTerraInput)
            XCTAssertEqual(pricing.findCodexModelPrice("gpt-5.6-sol", at: date(timestamp)).input, oldSolInput)
        }
        XCTAssertEqual(pricing.findCodexModelPrice("gpt-6.1-sol").cachedInput, 0.1)
        XCTAssertEqual(pricing.findModelPrice("gpt-6.1-sol").input, 2)
        XCTAssertEqual(pricing.findCodexModelPrice("gpt-6-sol").cachedInput, 0.2)
    }
}
