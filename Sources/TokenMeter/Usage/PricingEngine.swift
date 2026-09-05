import Foundation
import CryptoKit

final class PricingEngine {
    static let shared = PricingEngine()

    private let pricing: Pricing
    let cacheKey: String

    static func catalogFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private init() {
        let paths = [
            Bundle.main.url(forResource: "pricing", withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/pricing.json")
        ]

        var pricingData: Pricing?
        var catalogData = Data()
        for path in paths {
            if let url = path,
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(Pricing.self, from: data) {
                pricingData = decoded
                catalogData = data
                break
            }
        }

        self.cacheKey = Self.catalogFingerprint(catalogData)
        self.pricing = pricingData ?? Pricing(
            meta: .init(exchangeRateUSDtoCNY: 7.0, lastUpdated: "unknown"),
            modelsUSD: [:],
            fallbackModel: "qwen3.7-max",
            codexModelsUSD: [:],
            codexFallbackModel: "gpt-5.6-sol"
        )
    }

    func calculateCNY(usage: UsageRecord.TokenUsage, model: String, at timestamp: Date? = nil) -> Double {
        if model.isEmpty ||
           model == "<synthetic>" ||
           model.lowercased().contains("dogfooding") {
            return 0.0
        }

        let price = pricing.findModelPrice(model, at: timestamp)
        let rate = price.isCNY ? 1.0 : pricing.meta.exchangeRateUSDtoCNY
        let contextInput = max(0, usage.input)
            + max(0, usage.cacheWrite5m)
            + max(0, usage.cacheWrite1h)
            + max(0, usage.cacheRead)
        let rates = price.effectiveRates(inputTokens: contextInput)

        let usd = (
            Double(usage.input) * rates.input +
            Double(usage.output) * rates.output +
            Double(usage.cacheWrite5m) * rates.cacheWrite5m +
            Double(usage.cacheWrite1h) * rates.cacheWrite1h +
            Double(usage.cacheRead) * rates.cacheRead
        ) / 1_000_000.0

        return usd * rate
    }

    func calculateCodexCNY(
        input: Int,
        cachedInput: Int,
        cacheWriteInput: Int,
        output: Int,
        reasoning _: Int,
        model: String,
        serviceTier: String,
        at timestamp: Date? = nil
    ) -> Double {
        let price = pricing.findCodexModelPrice(model, at: timestamp)
        let rate = pricing.meta.exchangeRateUSDtoCNY

        let totalInput = max(0, input)
        let cached = min(totalInput, max(0, cachedInput))
        let cacheWrite = min(totalInput - cached, max(0, cacheWriteInput))
        let freshInput = totalInput - cached - cacheWrite
        let rates = price.effectiveRates(inputTokens: totalInput)

        let usd = (
            Double(freshInput) * rates.input +
            Double(cached) * rates.cachedInput +
            Double(cacheWrite) * rates.cacheWrite +
            Double(max(0, output)) * rates.output
        ) / 1_000_000.0

        return usd * rate * price.serviceTierMultiplier(serviceTier)
    }
}
