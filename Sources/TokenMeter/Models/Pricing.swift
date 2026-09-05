import Foundation

struct Pricing: Codable {
    let meta: Meta
    let modelsUSD: [String: ModelPrice]
    let fallbackModel: String
    let codexModelsUSD: [String: CodexModelPrice]
    let codexFallbackModel: String
    var priceHistory: [HistoricalPrices]? = nil

    /// Prior rates apply strictly before the cutoff; missing models use current rates.
    struct HistoricalPrices: Codable {
        let effectiveUntil: Date
        let modelsUSD: [String: ModelPrice]?
        let codexModelsUSD: [String: CodexModelPrice]?

        enum CodingKeys: String, CodingKey {
            case effectiveUntil = "effective_until"
            case modelsUSD = "models_usd_per_mtok"
            case codexModelsUSD = "codex_models_usd_per_mtok"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let cutoff = try values.decode(String.self, forKey: .effectiveUntil)
            guard let date = ISO8601DateFormatter().date(from: cutoff) else {
                throw DecodingError.dataCorruptedError(forKey: .effectiveUntil, in: values,
                    debugDescription: "Expected an ISO 8601 price cutoff with timezone")
            }
            effectiveUntil = date
            modelsUSD = try values.decodeIfPresent([String: ModelPrice].self, forKey: .modelsUSD)
            codexModelsUSD = try values.decodeIfPresent([String: CodexModelPrice].self, forKey: .codexModelsUSD)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(ISO8601DateFormatter().string(from: effectiveUntil), forKey: .effectiveUntil)
            try values.encodeIfPresent(modelsUSD, forKey: .modelsUSD)
            try values.encodeIfPresent(codexModelsUSD, forKey: .codexModelsUSD)
        }
    }

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
        let longContextThreshold: Int?
        let longContextInclusive: Bool?
        let longInput: Double?
        let longOutput: Double?
        let longCacheWrite5m: Double?
        let longCacheWrite1h: Double?
        let longCacheRead: Double?

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheWrite5m = "cache_write_5m"
            case cacheWrite1h = "cache_write_1h"
            case cacheRead = "cache_read"
            case currency
            case longContextThreshold = "long_context_threshold"
            case longContextInclusive = "long_context_inclusive"
            case longInput = "long_input"
            case longOutput = "long_output"
            case longCacheWrite5m = "long_cache_write_5m"
            case longCacheWrite1h = "long_cache_write_1h"
            case longCacheRead = "long_cache_read"
        }

        var isCNY: Bool {
            currency == "CNY"
        }

        func effectiveRates(inputTokens: Int) -> (
            input: Double,
            output: Double,
            cacheWrite5m: Double,
            cacheWrite1h: Double,
            cacheRead: Double
        ) {
            guard let threshold = longContextThreshold else {
                return (input, output, cacheWrite5m, cacheWrite1h, cacheRead)
            }

            let usesLongRates = longContextInclusive == true
                ? inputTokens >= threshold
                : inputTokens > threshold
            guard usesLongRates else {
                return (input, output, cacheWrite5m, cacheWrite1h, cacheRead)
            }

            return (
                longInput ?? input,
                longOutput ?? output,
                longCacheWrite5m ?? cacheWrite5m,
                longCacheWrite1h ?? cacheWrite1h,
                longCacheRead ?? cacheRead
            )
        }
    }

    struct CodexModelPrice: Codable {
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double?
        let output: Double
        let longContextThreshold: Int?
        let longInput: Double?
        let longCachedInput: Double?
        let longCacheWrite: Double?
        let longOutput: Double?
        let serviceTierMultipliers: [String: Double]?

        enum CodingKeys: String, CodingKey {
            case input
            case cachedInput = "cached_input"
            case cacheWrite = "cache_write"
            case output
            case longContextThreshold = "long_context_threshold"
            case longInput = "long_input"
            case longCachedInput = "long_cached_input"
            case longCacheWrite = "long_cache_write"
            case longOutput = "long_output"
            case serviceTierMultipliers = "service_tier_multipliers"
        }

        func effectiveRates(inputTokens: Int) -> (input: Double, cachedInput: Double, cacheWrite: Double, output: Double) {
            guard let threshold = longContextThreshold, inputTokens > threshold else {
                return (input, cachedInput, cacheWrite ?? input, output)
            }
            return (
                longInput ?? input,
                longCachedInput ?? cachedInput,
                longCacheWrite ?? longInput ?? cacheWrite ?? input,
                longOutput ?? output
            )
        }

        func serviceTierMultiplier(_ serviceTier: String) -> Double {
            serviceTierMultipliers?[serviceTier.lowercased()] ?? 1.0
        }
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case modelsUSD = "models_usd_per_mtok"
        case fallbackModel = "fallback_model"
        case codexModelsUSD = "codex_models_usd_per_mtok"
        case codexFallbackModel = "codex_fallback_model"
        case priceHistory = "price_history"
    }
}

extension Pricing {
    func findModelPrice(_ model: String, at timestamp: Date? = nil) -> ModelPrice {
        let key = modelsUSD[model] != nil ? model : modelsUSD.keys
            .filter { model.isPricingVariant(of: $0) }
            .max(by: { $0.count < $1.count }) ?? fallbackModel

        if let timestamp,
           let history = priceHistory?.filter({
               timestamp < $0.effectiveUntil && $0.modelsUSD?[key] != nil
           }).min(by: { $0.effectiveUntil < $1.effectiveUntil }),
           let price = history.modelsUSD?[key] {
            return price
        }
        return modelsUSD[key] ?? modelsUSD[fallbackModel] ?? modelsUSD.values.first!
    }

    func findCodexModelPrice(_ model: String, at timestamp: Date? = nil) -> CodexModelPrice {
        let key = codexModelsUSD[model] != nil ? model : codexModelsUSD.keys
            .filter { model.isPricingVariant(of: $0) }
            .max(by: { $0.count < $1.count }) ?? codexFallbackModel

        if let timestamp,
           let history = priceHistory?.filter({
               timestamp < $0.effectiveUntil && $0.codexModelsUSD?[key] != nil
           }).min(by: { $0.effectiveUntil < $1.effectiveUntil }),
           let price = history.codexModelsUSD?[key] {
            return price
        }
        return codexModelsUSD[key] ?? codexModelsUSD[codexFallbackModel] ?? codexModelsUSD.values.first!
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
