import Foundation

struct Pricing: Codable {
    let meta: Meta
    let modelsUSD: [String: ModelPrice]
    let fallbackModel: String
    let codexModelsUSD: [String: CodexModelPrice]
    let codexFallbackModel: String

    struct Meta: Codable {
        let exchangeRateUSDtoCNY: Double
        let lastUpdated: String

        enum CodingKeys: String, CodingKey {
            case exchangeRateUSDtoCNY = "usd_to_cny_rate"
            case lastUpdated = "last_updated"
        }
    }

    struct ModelPrice: Codable {
        let input: Double
        let output: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheWrite5m = "cache_write_5m"
            case cacheWrite1h = "cache_write_1h"
            case cacheRead = "cache_read"
            case currency
        }

        var isCNY: Bool {
            currency == "CNY"
        }
    }

    struct CodexModelPrice: Codable {
        let input: Double
        let cachedInput: Double
        let output: Double
        let longContextThreshold: Int?
        let longInput: Double?
        let longCachedInput: Double?
        let longOutput: Double?

        enum CodingKeys: String, CodingKey {
            case input
            case cachedInput = "cached_input"
            case output
            case longContextThreshold = "long_context_threshold"
            case longInput = "long_input"
            case longCachedInput = "long_cached_input"
            case longOutput = "long_output"
        }

        func effectiveRates(inputTokens: Int) -> (input: Double, cachedInput: Double, output: Double) {
            guard let threshold = longContextThreshold, inputTokens > threshold else {
                return (input, cachedInput, output)
            }
            return (
                longInput ?? input,
                longCachedInput ?? cachedInput,
                longOutput ?? output
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case modelsUSD = "models_usd_per_mtok"
        case fallbackModel = "fallback_model"
        case codexModelsUSD = "codex_models_usd_per_mtok"
        case codexFallbackModel = "codex_fallback_model"
    }
}

extension Pricing {
    func findModelPrice(_ model: String) -> ModelPrice {
        if let price = modelsUSD[model] {
            return price
        }

        if let key = modelsUSD.keys
            .filter({ model.isPricingVariant(of: $0) })
            .max(by: { $0.count < $1.count }) {
            return modelsUSD[key]!
        }

        return modelsUSD[fallbackModel] ?? modelsUSD.values.first!
    }

    func findCodexModelPrice(_ model: String) -> CodexModelPrice {
        if let price = codexModelsUSD[model] {
            return price
        }

        if let key = codexModelsUSD.keys
            .filter({ model.isPricingVariant(of: $0) })
            .max(by: { $0.count < $1.count }) {
            return codexModelsUSD[key]!
        }

        return codexModelsUSD[codexFallbackModel] ?? codexModelsUSD.values.first!
    }
}

private extension String {
    func isPricingVariant(of baseModel: String) -> Bool {
        guard self != baseModel, hasPrefix(baseModel) else { return false }
        let suffix = dropFirst(baseModel.count)
        return suffix.hasPrefix("-") || suffix.hasPrefix("[") ||
            suffix.hasPrefix(":") || suffix.hasPrefix("@")
    }
}
