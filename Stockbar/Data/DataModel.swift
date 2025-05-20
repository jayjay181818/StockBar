// Stockbar/Stockbar/Data/DataModel.swift
// --- COMPLETELY REPLACED FILE ---

import Combine
import Foundation
import OSLog // Use Apple's unified logging

class DataModel: ObservableObject {
    static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"] // Keep as is

    // MARK: - Properties

    // --- SWITCHED SERVICE ---
    // Use the Python script-based service implementation
    private let networkService: NetworkService = PythonNetworkService()
    // ------------------------

    private let currencyConverter: CurrencyConverter // Keep as is
    private let decoder = JSONDecoder()             // Keep as is
    private let encoder = JSONEncoder()             // Keep as is
    private var cancellables = Set<AnyCancellable>()// Keep as is

    @Published var realTimeTrades: [RealTimeTrade] = [] // Keep as is
    @Published var showColorCoding: Bool = UserDefaults.standard.bool(forKey: "showColorCoding") { // Keep as is
        didSet {
            UserDefaults.standard.set(showColorCoding, forKey: "showColorCoding")
        }
    }
    @Published var preferredCurrency: String = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "USD" { // Keep as is
        didSet {
            UserDefaults.standard.set(preferredCurrency, forKey: "preferredCurrency")
        }
    }

    private let logger = Logger.shared

    // MARK: - Initialization

    init(currencyConverter: CurrencyConverter = CurrencyConverter()) {
        // Ensure network service uses the correct implementation
        // self.networkService = PythonNetworkService() // Already done in property declaration

        self.currencyConverter = currencyConverter

        // Load saved trades
        let data = UserDefaults.standard.object(forKey: "usertrades") as? Data ?? Data()
        // Decode saved trades or default to empty
        let decodedTrades = (try? decoder.decode([Trade].self, from: data)) ?? []
        self.realTimeTrades = decodedTrades.map { RealTimeTrade(trade: $0, realTimeInfo: TradingInfo()) }
        if self.realTimeTrades.isEmpty {
            logger.warning("No saved trades found, starting with empty list.")
        }

        setupPublishers() // Keep as is
        logger.info("DataModel initialized with \(realTimeTrades.count) trades, using PythonNetworkService")
    }

     // Helper function for default trades if needed
    private func defaultTrades() -> [Trade] {
        // Return an empty array or some default sample trades
        // Example: return [Trade(name: "AAPL", ...)]
        logger.warning("No saved trades found, starting with empty list.")
        return []
    }

    // MARK: - Public Methods

    /// Refreshes all stock data from the network using the configured networkService
    @objc func refreshAllTrades() async {
        logger.info("Starting refresh for all trades using PythonNetworkService")
        // Prevent refresh if no trades are loaded
        guard !realTimeTrades.isEmpty else {
            logger.info("No trades to refresh.")
            return
        }
        let symbols = realTimeTrades.map { $0.trade.name }

        do {
            // This now calls PythonNetworkService.fetchBatchQuotes
            let results = try await networkService.fetchBatchQuotes(for: symbols)

            guard !results.isEmpty else {
                 logger.warning("Refresh completed but received no results from network service.")
                 return
             }

            // Update each trade with its corresponding result
            let resultDict = Dictionary(uniqueKeysWithValues: results.map { ($0.symbol, $0) })
            for idx in self.realTimeTrades.indices {
                let symbol = self.realTimeTrades[idx].trade.name
                if let res = resultDict[symbol] {
                    self.realTimeTrades[idx].updateWithResult(res)
                    logger.debug("Updated trade \(symbol) from refresh result.")
                } else {
                    logger.warning("No result returned for symbol \(symbol).")
                }
            }
            logger.info("Successfully refreshed \(results.count) trades of \(symbols.count) requested.")
        } catch {
            // Log the specific error from NetworkError enum if possible
            if let networkError = error as? NetworkError {
                 logger.error("Failed to refresh trades: \(networkError.localizedDescription)")
             } else {
                 logger.error("Failed to refresh trades (unknown error): \(error.localizedDescription)")
             }
        }
    }

    /// Calculates the total net gains across all trades - Keep as is (logic depends on RealTimeTrade values)
    func calculateNetGains() -> (amount: Double, currency: String) {
        // This logic should still work as long as RealTimeTrade.realTimeInfo gets updated
        // with currentPrice from the StockFetchResult
        logger.debug("Calculating net gains in \(preferredCurrency)")
        var totalGainsUSD = 0.0

        for realTimeTradeItem in realTimeTrades {
            // Ensure price is valid before calculation
            guard !realTimeTradeItem.realTimeInfo.currentPrice.isNaN,
                  realTimeTradeItem.realTimeInfo.currentPrice != 0 else { // Avoid division by zero or using placeholder price
                logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid price.")
                continue
            }

            // Ensure position cost is valid
             guard let rawCost = Double(realTimeTradeItem.trade.position.positionAvgCostString), rawCost > 0 else {
                 logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid cost.")
                 continue
             }

            let rawPrice = realTimeTradeItem.realTimeInfo.currentPrice
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency // Might be nil now

            // Calculate raw gains in original currency
            let rawGains = (rawPrice - rawCost) * units

            // Convert to USD (Handle potential nil currency - maybe default to USD or skip?)
            // If currency is often nil now, this conversion logic needs review
            var gainsInUSD = rawGains
            if let knownCurrency = currency {
                if knownCurrency == "GBX" || knownCurrency == "GBp" {
                     let gbpAmount = rawGains / 100.0
                     gainsInUSD = currencyConverter.convert(amount: gbpAmount, from: "GBP", to: "USD")
                 } else if knownCurrency != "USD" { // Only convert if not already USD
                     gainsInUSD = currencyConverter.convert(amount: rawGains, from: knownCurrency, to: "USD")
                 }
                // If knownCurrency is USD, gainsInUSD remains rawGains
            } else {
                // Assume USD if currency is nil? Or log a warning?
                 logger.warning("Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for gain calculation.")
                 // gainsInUSD remains rawGains
            }


            totalGainsUSD += gainsInUSD
        }

        // Convert final total to preferred currency - Keep as is
        var finalAmount = totalGainsUSD
         if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
             let gbpAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: "GBP")
             finalAmount = gbpAmount * 100.0 // Convert GBP to GBX
         } else if preferredCurrency != "USD" { // Only convert if not already USD
             finalAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: preferredCurrency)
         }
        // If preferredCurrency is USD, finalAmount remains totalGainsUSD


        logger.debug("Net gains calculated: \(finalAmount) \(preferredCurrency)")
        return (finalAmount, preferredCurrency)
    }


    // MARK: - Private Methods

    // Keep setupPublishers and saveTrades as they are
    private func setupPublishers() {
        $realTimeTrades
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] trades in
                guard let self = self else { return }
                self.saveTrades(trades)
            }
            .store(in: &cancellables)
    }

    private func saveTrades(_ trades: [RealTimeTrade]) {
        logger.debug("Saving \(trades.count) trades to UserDefaults")
        do {
            // Filter out any potential placeholder/empty trades before saving if needed
            let tradesToSave = trades.filter { !$0.trade.name.isEmpty }
            let tradesData = try encoder.encode(tradesToSave.map { $0.trade })
            UserDefaults.standard.set(tradesData, forKey: "usertrades")
            logger.debug("Successfully saved \(tradesToSave.count) trades.")
        } catch {
            logger.error("Failed to save trades: \(error.localizedDescription)")
        }
    }
}

// MARK: - RealTimeTrade Extension

extension RealTimeTrade {
    /// Updates the trade with new data from the network service
    func updateWithResult(_ result: StockFetchResult) {
        // Fallback logic: treat as GBX if currency is GBX/GBp or symbol ends with .L
        var price = result.regularMarketPrice
        var prevClose = result.regularMarketPreviousClose
        if price.isNaN {
            price = prevClose
        }
        var currency = result.currency
        let symbol = result.symbol
        var isGBX = false
        if let c = currency, c == "GBX" || c == "GBp" {
            isGBX = true
        } else if symbol.uppercased().hasSuffix(".L") {
            isGBX = true
        }
        if isGBX {
            price = price / 100.0
            prevClose = prevClose / 100.0
            currency = "GBP"
        }
        self.realTimeInfo.currentPrice = price
        self.realTimeInfo.previousClose = prevClose
        self.realTimeInfo.currency = currency // Now always GBP for GBX/GBp or .L
        self.realTimeInfo.lastUpdateTime = result.regularMarketTime // Using fetch time placeholder
        self.realTimeInfo.shortName = result.shortName ?? self.trade.name // Use symbol if name nil

        let logger = Logger.shared
        logger.debug("Updated trade \(self.trade.name): Price \(self.realTimeInfo.currentPrice) PrevClose: \(self.realTimeInfo.previousClose)")
    }
}