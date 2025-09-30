import Combine
import Foundation

public class CurrencyConverter: ObservableObject {
    @Published public var exchangeRates: [String: Double] = [:]
    private let baseURL = "https://api.exchangerate-api.com/v4/latest/USD"
    private var lastRefreshTime: Date = Date.distantPast
    private let refreshCooldown: TimeInterval = 300 // 5 minutes minimum between refreshes

    public init() {
        refreshRates()
    }

    public func refreshRates() {
        // Throttle refresh requests to prevent excessive API calls
        let now = Date()
        let timeSinceLastRefresh = now.timeIntervalSince(lastRefreshTime)
        
        guard timeSinceLastRefresh >= refreshCooldown else {
            Task { await Logger.shared.debug("💱 [CurrencyConverter] Skipping refresh - last refresh was \(Int(timeSinceLastRefresh))s ago") }
            return
        }
        
        lastRefreshTime = now
        guard let url = URL(string: baseURL) else { return }
        
        Task { await Logger.shared.info("💱 [CurrencyConverter] Fetching exchange rates from API...") }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(ExchangeRateResponse.self, from: data) else {
                Task { await Logger.shared.warning("💱 [CurrencyConverter] ❌ Failed to fetch exchange rates, using fallback rates") }
                return
            }

            DispatchQueue.main.async {
                self?.exchangeRates = response.rates
                Task {
                    await Logger.shared.info("💱 [CurrencyConverter] ✅ Successfully fetched exchange rates:")
                    await Logger.shared.info("💱 [CurrencyConverter] USD to GBP: \(response.rates["GBP"] ?? 0.0)")
                    await Logger.shared.info("💱 [CurrencyConverter] USD to EUR: \(response.rates["EUR"] ?? 0.0)")
                    if let gbpRate = response.rates["GBP"] {
                        let gbpToUsd = 1.0 / gbpRate
                        await Logger.shared.debug("💱 [CurrencyConverter] GBP to USD: \(gbpToUsd) (£1 = $\(String(format: "%.4f", gbpToUsd)))")
                    }
                }
            }
        }.resume()
    }

    public func convert(amount: Double, from: String, to: String) -> Double {
        // If same currency, return original amount
        if from == to {
            return amount
        }
        
        Task { await Logger.shared.debug("💱 [CurrencyConverter] Converting \(amount) from \(from) to \(to)") }
        
        // Handle USD as base currency (API uses USD as base)
        if from == "USD" {
            guard let targetRate = exchangeRates[to] else {
                // Fallback rates if API fails
                let fallbackRate = getFallbackRate(to: to)
                let result = amount * fallbackRate
                Task { await Logger.shared.debug("💱 [CurrencyConverter] Using FALLBACK rate: \(amount) USD × \(fallbackRate) = \(result) \(to)") }
                return result
            }
            let result = amount * targetRate
                            Task { await Logger.shared.debug("💱 [CurrencyConverter] Using API rate: \(amount) USD × \(targetRate) = \(result) \(to)") }
            return result
        } else if to == "USD" {
            guard let sourceRate = exchangeRates[from] else {
                // Fallback rates if API fails
                let fallbackRate = getFallbackRate(to: from)
                let result = amount / fallbackRate
                Task { await Logger.shared.debug("💱 [CurrencyConverter] Using FALLBACK rate: \(amount) \(from) ÷ \(fallbackRate) = \(result) USD") }
                return result
            }
            let result = amount / sourceRate
                            Task { await Logger.shared.debug("💱 [CurrencyConverter] Using API rate: \(amount) \(from) ÷ \(sourceRate) = \(result) USD") }
            return result
        } else {
            // Convert from source to USD, then USD to target
            guard let sourceRate = exchangeRates[from],
                  let targetRate = exchangeRates[to] else {
                // Fallback conversion
                let fallbackFromRate = getFallbackRate(to: from)
                let fallbackToRate = getFallbackRate(to: to)
                let usdAmount = amount / fallbackFromRate
                let result = usdAmount * fallbackToRate
                Task { await Logger.shared.debug("💱 [CurrencyConverter] Using FALLBACK rates: \(amount) \(from) ÷ \(fallbackFromRate) × \(fallbackToRate) = \(result) \(to)") }
                return result
            }
            let amountInUSD = amount / sourceRate
            let result = amountInUSD * targetRate
                            Task { await Logger.shared.debug("💱 [CurrencyConverter] Using API rates: \(amount) \(from) ÷ \(sourceRate) × \(targetRate) = \(result) \(to)") }
            return result
        }
    }
    
    private func getFallbackRate(to currency: String) -> Double {
        // Fallback exchange rates (current as of June 7, 2025) - these are USD to target currency rates
        // For example: 1 USD = 0.7387 GBP means to convert USD to GBP we multiply by 0.7387
        switch currency {
        case "GBP": return 0.7387  // 1 USD = 0.7387 GBP (£1 = 1.3537668 USD)
        case "EUR": return 0.85  // 1 USD = 0.85 EUR  
        case "JPY": return 110.0 // 1 USD = 110 JPY
        case "CAD": return 1.25  // 1 USD = 1.25 CAD
        case "AUD": return 1.35  // 1 USD = 1.35 AUD
        default: return 1.0
        }
    }
}

// Response model for the API
private struct ExchangeRateResponse: Codable {
    let rates: [String: Double]
}
