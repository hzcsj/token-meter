import Foundation

final class PricingEngine {
    static let shared = PricingEngine()

    private let pricing: Pricing

    private init() {
        let paths = [
            Bundle.main.url(forResource: "pricing", withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/pricing.json")
        ]

        var pricingData: Pricing?
        for path in paths {
            if let url = path,
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(Pricing.self, from: data) {
                pricingData = decoded
                break
            }
        }

        self.pricing = pricingData ?? Pricing(
            meta: .init(exchangeRateUSDtoCNY: 7.0, lastUpdated: "unknown"),
            modelsUSD: [:],
            fallbackModel: "qwen3.7-max",
            codexModelsUSD: [:],
            codexFallbackModel: "gpt-5.6-sol"
        )
    }

    func calculateCNY(usage: UsageRecord.TokenUsage, model: String) -> Double {
        if model.isEmpty ||
           model == "<synthetic>" ||
           model.lowercased().contains("dogfooding") {
            return 0.0
        }

        let price = pricing.findModelPrice(model)
        let rate = price.isCNY ? 1.0 : pricing.meta.exchangeRateUSDtoCNY

        let usd = (
            Double(usage.input) * price.input +
            Double(usage.output) * price.output +
            Double(usage.cacheWrite5m) * price.cacheWrite5m +
            Double(usage.cacheWrite1h) * price.cacheWrite1h +
            Double(usage.cacheRead) * price.cacheRead
        ) / 1_000_000.0

        return usd * rate
    }

    func calculateCodexCNY(input: Int, cachedInput: Int, output: Int, reasoning: Int, model: String, serviceTier: String) -> Double {
        let price = pricing.findCodexModelPrice(model)
        let rate = pricing.meta.exchangeRateUSDtoCNY

        let nonCachedInput = max(0, input - cachedInput)
        let rates = price.effectiveRates(inputTokens: input)

        let usd = (
            Double(nonCachedInput) * rates.input +
            Double(cachedInput) * rates.cachedInput +
            Double(output + reasoning) * rates.output
        ) / 1_000_000.0

        var cost = usd * rate

        if serviceTier == "priority" {
            cost *= 1.5
        }

        return cost
    }
}
