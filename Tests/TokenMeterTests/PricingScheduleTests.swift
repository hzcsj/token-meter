import XCTest
@testable import TokenMeter

final class PricingScheduleTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func catalog() throws -> Pricing {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pricing.json")
        return try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
    }

    func testNewMappingsAndVariants() throws {
        let pricing = try catalog()
        for (model, input, output, read, write) in [
            ("claude-sonnet-5-5", 2.0, 10.0, 0.1, 2.5),
            ("claude-haiku-5-5", 0.1, 0.5, 0.01, 0.125),
            ("qwen3.8-max", 12, 36, 1, 15),
            ("qwen3.8-flash", 0.8, 2.7, 0.1, 1.25),
            ("qwen3.8-2.4t-a95b", 12, 36, 1, 15),
            ("qwen3.8-27b", 3, 12, 0.3, 3.75),
            ("glm-5.3", 8, 28, 2, 8),
            ("glm-5.3-flash", 0.8, 2.8, 0.23, 0.8),
            ("glm-5.3-flashx", 2, 7, 0.57, 2),
        ] {
            for variant in [model, model + "-20260928", model + "[1m]"] {
                let price = pricing.findModelPrice(variant)
                XCTAssertEqual(price.input, input, variant)
                XCTAssertEqual(price.output, output, variant)
                XCTAssertEqual(price.cacheRead, read, variant)
                XCTAssertEqual(price.cacheWrite5m, write, variant)
                XCTAssertEqual(price.isCNY, !model.hasPrefix("claude"), variant)
            }
        }
        XCTAssertEqual(pricing.findModelPrice("claude-sonnet-5-5").cacheWrite1h, 4)
        XCTAssertEqual(pricing.findModelPrice("qwen3.7-max").cacheRead, 1.2)
        XCTAssertEqual(pricing.findModelPrice("glm-5.2").input, 8)
    }

    func testGeminiIntroductoryPricesExpireByEventTime() throws {
        let pricing = try catalog()
        for model in ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"] {
            let promo = pricing.findModelPrice(model, at: date("2026-12-31T23:59:59Z"))
            let standard = pricing.findModelPrice(model, at: date("2027-01-01T00:00:00Z"))
            XCTAssertEqual(promo.input, 0.75)
            XCTAssertEqual(promo.output, 3.75)
            XCTAssertEqual(promo.cacheRead, 0.075)
            XCTAssertEqual(standard.input, 1.5)
            XCTAssertEqual(standard.output, 7.5)
            XCTAssertEqual(standard.cacheRead, 0.15)
        }
        XCTAssertEqual(pricing.findModelPrice("gemini-3.6-flash", at: date("2026-09-28T23:59:59Z")).input, 1.5)
        XCTAssertEqual(pricing.findModelPrice("gemini-3.6-flash", at: date("2026-09-29T00:00:00Z")).input, 0.75)
        let now = Date()
        XCTAssertEqual(pricing.findModelPrice("gemini-3.8-flash").input,
                       pricing.findModelPrice("gemini-3.8-flash", at: now).input)
    }

    func testGeminiArgonPromotionUsesEventTimeWithoutAContextSurcharge() throws {
        let pricing = try catalog()
        let restored = try JSONDecoder().decode(Pricing.self, from: JSONEncoder().encode(pricing))
        let usage = UsageRecord.TokenUsage(input: 300_000, output: 100_000,
            cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 600_000)
        for model in ["gemini-4-argon", "gemini-4-argon-20261013", "gemini-4-argon[1m]"] {
            for (timestamp, input, output, read, cost): (String, Double, Double, Double, Double) in [
                ("2026-10-13T00:00:00Z", 2, 10, 0.1, 11.62),
                ("2026-11-30T23:59:59Z", 2, 10, 0.1, 11.62),
                ("2026-12-01T00:00:00Z", 4, 20, 0.2, 23.24),
                ("2026-12-01T08:00:00+08:00", 4, 20, 0.2, 23.24),
            ] {
                let price = restored.findModelPrice(model, at: date(timestamp))
                XCTAssertEqual(price.input, input)
                XCTAssertEqual(price.output, output)
                XCTAssertEqual(price.cacheRead, read)
                XCTAssertEqual(price.cacheWrite5m, input)
                XCTAssertEqual(price.cacheWrite1h, input)
                XCTAssertNil(price.longContextThreshold)
                XCTAssertEqual(price.effectiveRates(inputTokens: 900_000).input, input)
                XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: model,
                    at: date(timestamp)), cost, accuracy: 0.000001)
            }
        }
        // Argon's promotion must not alter the separate Flash promotion.
        XCTAssertEqual(restored.findModelPrice("gemini-3.8-flash", at: date("2026-12-01T00:00:00Z")).input, 0.75)
        XCTAssertEqual(restored.findCodexModelPrice("gpt-6.1-sol").input, 2)
    }

    func testGemini35MigrationPreservesOldCostsAndDoesNotRepriceFlashLite() throws {
        var pricing = try catalog()
        pricing.priceHistory = pricing.priceHistory?.reversed()
        let restored = try JSONDecoder().decode(Pricing.self, from: JSONEncoder().encode(pricing))
        let usage = UsageRecord.TokenUsage(input: 100_000, output: 10_000,
            cacheWrite5m: 20_000, cacheWrite1h: 10_000, cacheRead: 200_000)
        for (time, input, output, cost) in [
            ("2026-10-07T23:59:59Z", 1.5, 9.0, 2.205),
            ("2026-10-08T00:00:00Z", 0.75, 3.75, 1.05),
            ("2026-10-08T08:00:00+08:00", 0.75, 3.75, 1.05),
            ("2026-12-31T23:59:59Z", 0.75, 3.75, 1.05),
            ("2027-01-01T00:00:00Z", 1.5, 7.5, 2.10),
        ] {
            let timestamp = date(time)
            let price = restored.findModelPrice("gemini-3.5-flash", at: timestamp)
            XCTAssertEqual(price.input, input)
            XCTAssertEqual(price.output, output)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage,
                model: "gemini-3.5-flash", at: timestamp), cost, accuracy: 0.000001)
            for model in ["gemini-3.5-flash-lite", "gemini-3.5-flash-lite[1m]"] {
                XCTAssertEqual(restored.findModelPrice(model, at: timestamp).output, 2.5)
                XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage,
                    model: model, at: timestamp), 0.49, accuracy: 0.000001)
            }
        }
    }

    func testHaiku55ContextTierIncludesEveryInputPartition() throws {
        let pricing = try catalog()
        for model in ["claude-haiku-5-5", "claude-haiku-5-5-20261007", "claude-haiku-5-5[1m]"] {
            let price = pricing.findModelPrice(model, at: date("2026-10-07T12:00:00Z"))
            let short = price.effectiveRates(inputTokens: 100_000)
            XCTAssertEqual(short.input, 0.1)
            XCTAssertEqual(short.output, 0.5)
            XCTAssertEqual(short.cacheWrite5m, 0.125)
            XCTAssertEqual(short.cacheWrite1h, 0.2)
            XCTAssertEqual(short.cacheRead, 0.01)
            let long = price.effectiveRates(inputTokens: 100_001)
            XCTAssertEqual(long.input, 0.5)
            XCTAssertEqual(long.output, 2.5)
            XCTAssertEqual(long.cacheWrite5m, 0.625)
            XCTAssertEqual(long.cacheWrite1h, 1)
            XCTAssertEqual(long.cacheRead, 0.05)
            for (fresh, expected) in [(20_000, 0.0973), (20_001, 0.4865035)] {
                let usage = UsageRecord.TokenUsage(input: fresh, output: 10_000,
                    cacheWrite5m: 20_000, cacheWrite1h: 20_000, cacheRead: 40_000)
                XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: model),
                               expected, accuracy: 0.000001, model)
            }
            for (cached, expected) in [(100_000, 0.007), (100_001, 0.03500035)] {
                let usage = UsageRecord.TokenUsage(input: 0, output: 0,
                    cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: cached)
                XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: model),
                               expected, accuracy: 0.000001, model)
            }
            // Output tokens do not move a short prompt into the long-input tier.
            let usage = UsageRecord.TokenUsage(input: 0, output: 128_000,
                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 100_000)
            XCTAssertEqual(PricingEngine.shared.calculateCNY(usage: usage, model: model),
                           0.455, accuracy: 0.000001, model)
        }
        XCTAssertEqual(pricing.findModelPrice("claude-haiku-4-5").input, 1)
    }

    func testDeepSeekPeakBoundariesUseUTC() throws {
        let pricing = try catalog()
        let price = pricing.findModelPrice("deepseek-flash")
        for (time, multiplier) in [
            ("00:59:59", 0.5), ("01:00:00", 1.0), ("03:59:59", 1.0), ("04:00:00", 0.5),
            ("05:59:59", 0.5), ("06:00:00", 1.0), ("09:59:59", 1.0), ("10:00:00", 0.5),
        ] {
            XCTAssertEqual(pricing.timeMultiplier(for: price, at: date("2026-09-29T\(time)Z")), multiplier)
        }
        XCTAssertEqual(pricing.timeMultiplier(for: price, at: date("2026-09-29T09:00:00+08:00")), 1)
    }

    func testDeepSeekHolidaysAndWeekendsAreOffPeak() throws {
        let pricing = try catalog()
        let price = pricing.findModelPrice("deepseek-v4-pro")
        for day in ["2026-09-25", "2026-09-26", "2026-09-27", "2026-10-01", "2026-10-07", "2026-10-10"] {
            XCTAssertEqual(pricing.timeMultiplier(for: price, at: date(day + "T02:00:00Z")), 0.5, day)
        }
        XCTAssertEqual(pricing.timeMultiplier(for: price, at: date("2026-10-08T02:00:00Z")), 1)
    }

    func testDeepSeekHistoricalEntriesDoNotGainNewSchedules() throws {
        let pricing = try catalog()
        let proOld = pricing.findModelPrice("deepseek-v4-pro", at: date("2026-08-16T15:59:59Z"))
        let proNew = pricing.findModelPrice("deepseek-v4-pro", at: date("2026-08-16T16:00:00Z"))
        XCTAssertEqual(proOld.input, 0.435)
        XCTAssertNil(proOld.timeSchedule)
        XCTAssertEqual(proNew.input, 1.32)
        XCTAssertEqual(pricing.timeMultiplier(for: proOld, at: date("2026-09-26T02:00:00Z")), 1)
        for variant in ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            let old = pricing.findModelPrice(variant, at: date("2026-09-10T03:59:59Z"))
            XCTAssertEqual(old.input, 0.14)
            XCTAssertNil(old.timeSchedule)
            XCTAssertEqual(pricing.findModelPrice(variant, at: date("2026-09-10T04:00:00Z")).input, 0.3)
        }
        XCTAssertEqual(pricing.findModelPrice("deepseek-chat").input, 0.14)
        XCTAssertEqual(pricing.findModelPrice("deepseek-reasoner").input, 0.14)
    }

    func testSchedulesApplyToAllTokenPartitionsAndSurviveReload() throws {
        let pricing = try catalog()
        let restored = try JSONDecoder().decode(Pricing.self, from: JSONEncoder().encode(pricing))
        XCTAssertEqual(restored.timeMultiplier(for: restored.findModelPrice("deepseek-flash"),
                                              at: date("2026-09-29T04:00:00Z")), 0.5)
        let usage = UsageRecord.TokenUsage(input: 100_000, output: 100_000,
            cacheWrite5m: 100_000, cacheWrite1h: 100_000, cacheRead: 100_000)
        let peak = PricingEngine.shared.calculateCNY(usage: usage, model: "deepseek-flash", at: date("2026-09-29T01:00:00Z"))
        let offPeak = PricingEngine.shared.calculateCNY(usage: usage, model: "deepseek-flash", at: date("2026-09-29T04:00:00Z"))
        XCTAssertEqual(peak, 1.4742, accuracy: 0.000001)
        XCTAssertEqual(offPeak, peak / 2, accuracy: 0.000001)
    }
}
