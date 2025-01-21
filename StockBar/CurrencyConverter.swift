import Foundation
import Combine

public class CurrencyConverter: ObservableObject {
    @Published public var exchangeRates: [String: Double] = [:]
    private let baseURL = "https://api.exchangerate-api.com/v4/latest/USD"
    
    public init() {
        refreshRates()
    }
    
    public func refreshRates() {
        guard let url = URL(string: baseURL) else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
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
        guard let sourceRate = exchangeRates[from],
              let targetRate = exchangeRates[to] else {
            return amount
        }
        
        // Convert to USD first (base currency), then to target currency
        let amountInUSD = amount / sourceRate
        return amountInUSD * targetRate
    }
}

// Response model for the API
private struct ExchangeRateResponse: Codable {
    let rates: [String: Double]
}