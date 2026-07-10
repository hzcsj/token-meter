import XCTest
@testable import TokenMeter

final class PricingTests: XCTestCase {
    private func pricing() throws -> Pricing {
        let json = #"""
        {
          "_meta": {"usd_to_cny_rate": 7, "last_updated": "2026-07-10"},
          "models_usd_per_mtok": {
            "claude-sonnet-5": {"input": 3, "output": 15, "cache_write_5m": 3.75, "cache_write_1h": 6, "cache_read": 0.3},
            "qwen3.7-max": {"input": 12, "output": 36, "cache_write_5m": 15, "cache_write_1h": 15, "cache_read": 1.2, "currency": "CNY"}
          },
          "fallback_model": "qwen3.7-max",
          "codex_models_usd_per_mtok": {
            "gpt-5": {"input": 1.25, "cached_input": 0.125, "output": 10},
            "gpt-5.4": {"input": 2.5, "cached_input": 0.25, "output": 15},
            "gpt-5.4-mini": {"input": 0.75, "cached_input": 0.075, "output": 4.5},
            "gpt-5.6-sol": {"input": 5, "cached_input": 0.5, "output": 30, "long_context_threshold": 272000, "long_input": 10, "long_cached_input": 1, "long_output": 45}
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
        XCTAssertEqual(try pricing().findModelPrice("claude-sonnet-5[1m]").input, 3)
    }

    func testLongContextRatesApplyAboveThreshold() throws {
        let price = try pricing().findCodexModelPrice("gpt-5.6-sol")
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_000).input, 5)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).input, 10)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).cachedInput, 1)
        XCTAssertEqual(price.effectiveRates(inputTokens: 272_001).output, 45)
    }
}
