import Combine
import Foundation

// Structure to store historical rate data
public struct CurrencyRateSnapshot: Codable {
    let timestamp: Date
    let rates: [String: Double]
    let baseCurrency: String
}

public class CurrencyConverter: ObservableObject {
    @Published public var exchangeRates: [String: Double] = [:]
    @Published public var lastRefreshTime: Date = Date.distantPast
    @Published public var lastRefreshSuccess: Bool = false
    private let baseURL = "https://api.exchangerate-api.com/v4/latest/USD"
    private let refreshCooldown: TimeInterval = 300 // 5 minutes minimum between refreshes
    
    // Currency history tracking (keep last 30 days)
    private var rateHistory: [CurrencyRateSnapshot] = []
    private let maxHistoryDays: Int = 30
    private let significantChangeThreshold: Double = 0.02 // 2% change threshold for alerts
    
    // Alert tracking to prevent spam
    private var lastAlertTimestamps: [String: Date] = [:] // currency pair -> last alert time
    private let alertCooldown: TimeInterval = 3600 // 1 hour between alerts for same pair

    public init() {
        loadRateHistory()
        refreshRates()
    }

    // Get exchange rate with metadata for UI display
    public func getExchangeRateInfo(from: String, to: String) -> (rate: Double, timestamp: Date, isFallback: Bool) {
        if from == to {
            return (1.0, lastRefreshTime, false)
        }

        // Determine if we're using fallback rates
        let usingFallback = exchangeRates.isEmpty || lastRefreshTime == Date.distantPast

        // Calculate rate
        let rate: Double
        if from == "USD" {
            rate = exchangeRates[to] ?? getFallbackRate(to: to)
        } else if to == "USD" {
            let sourceRate = exchangeRates[from] ?? getFallbackRate(to: from)
            rate = 1.0 / sourceRate
        } else {
            let sourceRate = exchangeRates[from] ?? getFallbackRate(to: from)
            let targetRate = exchangeRates[to] ?? getFallbackRate(to: to)
            rate = targetRate / sourceRate
        }

        return (rate, lastRefreshTime, usingFallback)
    }

    // Get formatted time since last refresh
    public func getTimeSinceRefresh() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(lastRefreshTime)

        if lastRefreshTime == Date.distantPast {
            return "Never"
        }

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
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
                DispatchQueue.main.async {
                    self?.lastRefreshSuccess = false
                }
                return
            }

            DispatchQueue.main.async {
                // Check for significant changes before updating
                self?.checkForSignificantChanges(newRates: response.rates)
                
                self?.exchangeRates = response.rates
                self?.lastRefreshSuccess = true
                
                // Save to history
                self?.addToHistory(rates: response.rates)
                
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
    
    // MARK: - Currency History Management
    
    private func addToHistory(rates: [String: Double]) {
        let snapshot = CurrencyRateSnapshot(timestamp: Date(), rates: rates, baseCurrency: "USD")
        rateHistory.append(snapshot)
        
        // Trim old history (keep only last 30 days)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date()) ?? Date()
        rateHistory = rateHistory.filter { $0.timestamp >= cutoffDate }
        
        saveRateHistory()
        Task { await Logger.shared.debug("💱 [CurrencyConverter] Saved rate history. Total snapshots: \(rateHistory.count)") }
    }
    
    private func saveRateHistory() {
        let defaults = UserDefaults.standard
        if let encoded = try? JSONEncoder().encode(rateHistory) {
            defaults.set(encoded, forKey: "currencyRateHistory")
        }
    }
    
    private func loadRateHistory() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "currencyRateHistory"),
           let history = try? JSONDecoder().decode([CurrencyRateSnapshot].self, from: data) {
            rateHistory = history
            Task { await Logger.shared.info("💱 [CurrencyConverter] Loaded \(history.count) historical rate snapshots") }
        }
    }
    
    // Get historical rate for a specific currency pair
    public func getRateHistory(from: String, to: String, days: Int = 30) -> [(date: Date, rate: Double)] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        return rateHistory
            .filter { $0.timestamp >= cutoffDate }
            .compactMap { snapshot -> (Date, Double)? in
                let rate: Double
                if from == "USD" {
                    guard let targetRate = snapshot.rates[to] else { return nil }
                    rate = targetRate
                } else if to == "USD" {
                    guard let sourceRate = snapshot.rates[from] else { return nil }
                    rate = 1.0 / sourceRate
                } else {
                    guard let sourceRate = snapshot.rates[from],
                          let targetRate = snapshot.rates[to] else { return nil }
                    rate = targetRate / sourceRate
                }
                return (snapshot.timestamp, rate)
            }
            .sorted { $0.date < $1.date }
    }
    
    // MARK: - Significant Change Detection
    
    private func checkForSignificantChanges(newRates: [String: Double]) {
        guard !exchangeRates.isEmpty else { return } // Skip on first fetch
        
        let now = Date()
        let majorCurrencies = ["GBP", "EUR", "JPY", "CAD", "AUD", "CHF"]
        
        for currency in majorCurrencies {
            guard let oldRate = exchangeRates[currency],
                  let newRate = newRates[currency] else { continue }
            
            let changePercent = abs((newRate - oldRate) / oldRate)
            
            if changePercent >= significantChangeThreshold {
                let pairKey = "USD-\(currency)"
                
                // Check alert cooldown
                if let lastAlert = lastAlertTimestamps[pairKey],
                   now.timeIntervalSince(lastAlert) < alertCooldown {
                    continue // Skip if alerted recently
                }
                
                // Send notification
                sendCurrencyChangeNotification(currency: currency, oldRate: oldRate, newRate: newRate, changePercent: changePercent)
                lastAlertTimestamps[pairKey] = now
            }
        }
    }
    
    private func sendCurrencyChangeNotification(currency: String, oldRate: Double, newRate: Double, changePercent: Double) {
        let direction = newRate > oldRate ? "increased" : "decreased"
        let changePercentFormatted = String(format: "%.2f%%", changePercent * 100)
        
        Task {
            await Logger.shared.info("💱🔔 [CurrencyConverter] Significant change detected: USD/\(currency) \(direction) by \(changePercentFormatted)")
            
            // Send macOS notification
            let notification = NSUserNotification()
            notification.title = "Significant Exchange Rate Change"
            notification.informativeText = "USD/\(currency) has \(direction) by \(changePercentFormatted) (\(String(format: "%.4f", oldRate)) → \(String(format: "%.4f", newRate)))"
            notification.soundName = NSUserNotificationDefaultSoundName
            
            NSUserNotificationCenter.default.deliver(notification)
        }
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
