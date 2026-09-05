import XCTest
@testable import TokenMeter

final class PricingTests: XCTestCase {
    private func pricing() throws -> Pricing {
        let json = #"""
        {
          "_meta": {"usd_to_cny_rate": 7, "last_updated": "2026-07-10"},
          "models_usd_per_mtok": {
            "claude-sonnet-5": {"input": 2, "output": 10, "cache_write_5m": 2.5, "cache_write_1h": 4, "cache_read": 0.2},
            "qwen3.7-max": {"input": 12, "output": 36, "cache_write_5m": 15, "cache_write_1h": 15, "cache_read": 1.2, "currency": "CNY"},
            "glm-5.1": {"input": 6, "output": 24, "cache_write_5m": 6, "cache_write_1h": 6, "cache_read": 1.3, "currency": "CNY", "long_context_threshold": 32000, "long_context_inclusive": true, "long_input": 8, "long_output": 28, "long_cache_write_5m": 8, "long_cache_write_1h": 8, "long_cache_read": 2}
          },
          "fallback_model": "qwen3.7-max",
          "codex_models_usd_per_mtok": {
            "gpt-5": {"input": 1.25, "cached_input": 0.125, "output": 10},
            "gpt-5.4": {"input": 2.5, "cached_input": 0.25, "output": 15},
            "gpt-5.4-mini": {"input": 0.75, "cached_input": 0.075, "output": 4.5},
            "gpt-5.6-sol": {"input": 5, "cached_input": 0.5, "cache_write": 6.25, "output": 30, "long_context_threshold": 272000, "long_input": 10, "long_cached_input": 1, "long_cache_write": 12.5, "long_output": 45, "service_tier_multipliers": {"fast": 2.5, "priority": 2}}
          },
          "codex_fallback_model": "gpt-5.6-sol"
        }
        """#
        return try JSONDecoder().decode(Pricing.self, from: Data(json.utf8))
    }

    func testFutureVersionUsesFallbackInsteadOfGenericGPT5() throws {
        XCTAssertEqual(try pricing().findCodexModelPrice("gpt-5.7").input, 5)
    }

    func testLongestVariantPrefixWins() throws {
        XCTAssertEqual(try pricing().findCodexModelPrice("gpt-5.4-mini-2026-07-10").input, 0.75)
        XCTAssertEqual(try pricing().findModelPrice("claude-sonnet-5[1m]").input, 2)
    }

    func testLongContextRatesApplyAboveThreshold() throws {
        let price = try pricing().findCodexModelPrice("gpt-5.6-sol")
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_000).input, 5)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).input, 10)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).cachedInput, 1)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).cacheWrite, 12.5)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).output, 45)
    }

    func testGenericInclusiveLongContextRates() throws {
        let price = try pricing().findModelPrice("glm-5.1")
        XCTAssertEqual(price.effectiveRates(inputTokens: 31_999).input, 6)
        XCTAssertEqual(price.effectiveRates(inputTokens: 32_000).input, 8)
        XCTAssertEqual(price.effectiveRates(inputTokens: 32_000).cacheRead, 2)
    }

    func testCodexOutputAlreadyIncludesReasoning() {
        let cost = PricingEngine.shared.calculateCodexCNY(
            input: 0,
            cachedInput: 0,
            cacheWriteInput: 0,
            output: 1_000_000,
            reasoning: 500_000,
            model: "gpt-5.6-sol",
            serviceTier: "default"
        )
        XCTAssertEqual(cost, 140, accuracy: 0.000_001)
    }

    func testCodexCacheWriteAndServiceTierRates() {
        let standard = PricingEngine.shared.calculateCodexCNY(
            input: 100_000,
            cachedInput: 0,
            cacheWriteInput: 100_000,
            output: 0,
            reasoning: 0,
            model: "gpt-5.6-sol",
            serviceTier: "default"
        )
        let fast = PricingEngine.shared.calculateCodexCNY(
            input: 100_000,
            cachedInput: 0,
            cacheWriteInput: 0,
            output: 0,
            reasoning: 0,
            model: "gpt-5.6-sol",
            serviceTier: "fast"
        )
        let priority = PricingEngine.shared.calculateCodexCNY(
            input: 100_000,
            cachedInput: 0,
            cacheWriteInput: 0,
            output: 0,
            reasoning: 0,
            model: "gpt-5.6-sol",
            serviceTier: "priority"
        )

        XCTAssertEqual(standard, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(fast, 5.6, accuracy: 0.000_001)
        XCTAssertEqual(priority, 5.6, accuracy: 0.000_001)
    }
}
