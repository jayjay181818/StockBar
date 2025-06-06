import Combine
import Foundation

public class CurrencyConverter: ObservableObject {
    @Published public var exchangeRates: [String: Double] = [:]
    private let baseURL = "https://api.exchangerate-api.com/v4/latest/USD"

    public init() {
        refreshRates()
    }

    public func refreshRates() {
        guard let url = URL(string: baseURL) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(ExchangeRateResponse.self, from: data) else {
                return
            }

            DispatchQueue.main.async {
                self?.exchangeRates = response.rates
            }
        }.resume()
    }

    public func convert(amount: Double, from: String, to: String) -> Double {
        // If same currency, return original amount
        if from == to {
            return amount
        }
        
        // Handle USD as base currency (API uses USD as base)
        if from == "USD" {
            guard let targetRate = exchangeRates[to] else {
                // Fallback rates if API fails
                return amount * getFallbackRate(to: to)
            }
            return amount * targetRate
        } else if to == "USD" {
            guard let sourceRate = exchangeRates[from] else {
                // Fallback rates if API fails
                return amount / getFallbackRate(to: from)
            }
            return amount / sourceRate
        } else {
            // Convert from source to USD, then USD to target
            guard let sourceRate = exchangeRates[from],
                  let targetRate = exchangeRates[to] else {
                // Fallback conversion
                let usdAmount = amount / getFallbackRate(to: from)
                return usdAmount * getFallbackRate(to: to)
            }
            let amountInUSD = amount / sourceRate
            return amountInUSD * targetRate
        }
    }
    
    private func getFallbackRate(to currency: String) -> Double {
        // Fallback exchange rates (approximate)
        switch currency {
        case "GBP": return 0.79
        case "EUR": return 0.85
        case "JPY": return 110.0
        case "CAD": return 1.25
        case "AUD": return 1.35
        default: return 1.0
        }
    }
}

// Response model for the API
private struct ExchangeRateResponse: Codable {
    let rates: [String: Double]
}
