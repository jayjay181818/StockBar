// Stockbar/Stockbar/Data/DataModel.swift
// --- COMPLETELY REPLACED FILE ---

import Combine
import Foundation
// Removed OSLog import to avoid name clashes with our custom Logger

class DataModel: ObservableObject {
    static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"] // Keep as is

    // MARK: - Properties

    // --- SWITCHED SERVICE ---
    // Use the Python script-based service implementation
    private let networkService: NetworkService = PythonNetworkService()
    // ------------------------

    private let currencyConverter: CurrencyConverter // Keep as is
    private let decoder = JSONDecoder()           // Keep as is
    private let encoder = JSONEncoder()           // Keep as is
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

    private var refreshTimer: Timer?
    private var currentSymbolIndex = 0
    private let refreshInterval: TimeInterval = 900 // 15 minutes in seconds (changed from 5 minutes)
    
    // MARK: - Caching Properties
    private var lastSuccessfulFetch: [String: Date] = [:] // Track last successful fetch time per symbol
    private var lastFailedFetch: [String: Date] = [:] // Track last failed fetch time per symbol
    private let cacheInterval: TimeInterval = 900 // 15 minutes cache duration for successful fetches
    private let retryInterval: TimeInterval = 300 // 5 minutes retry interval for failed fetches
    private let maxCacheAge: TimeInterval = 3600 // 1 hour max cache age before forcing refresh

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
        
        // Load saved trading info (last successful stock data)
        loadSavedTradingInfo()
        
        if self.realTimeTrades.isEmpty {
            logger.warning("No saved trades found, starting with empty list.")
        }

        setupPublishers() // Keep as is
        logger.info("DataModel initialized with \(realTimeTrades.count) trades, using PythonNetworkService")
        startStaggeredRefresh()
    }

     // Helper function for default trades if needed
    private func defaultTrades() -> [Trade] {
        // Return an empty array or some default sample trades
        // Example: return [Trade(name: "AAPL", ...)]
        logger.warning("No saved trades found, starting with empty list.")
        return []
    }
    
    // MARK: - Persistent Storage Methods
    
    private func loadSavedTradingInfo() {
        guard let data = UserDefaults.standard.object(forKey: "tradingInfoData") as? Data else {
            logger.info("No saved trading info found")
            return
        }
        
        do {
            let savedTradingInfo = try decoder.decode([String: TradingInfo].self, from: data)
            logger.info("Loaded saved trading info for \(savedTradingInfo.count) symbols")
            
            // Apply saved trading info to matching trades
            for trade in realTimeTrades {
                if let savedInfo = savedTradingInfo[trade.trade.name] {
                    trade.realTimeInfo = savedInfo
                    logger.debug("Restored trading info for \(trade.trade.name): Price \(savedInfo.currentPrice), Last Update: \(savedInfo.getTimeInfo())")
                }
            }
        } catch {
            logger.error("Failed to load saved trading info: \(error.localizedDescription)")
        }
    }
    
    private func saveTradingInfo() {
        let tradingInfoDict = Dictionary(uniqueKeysWithValues: realTimeTrades.map { ($0.trade.name, $0.realTimeInfo) })
        
        do {
            let data = try encoder.encode(tradingInfoDict)
            UserDefaults.standard.set(data, forKey: "tradingInfoData")
            logger.debug("Saved trading info for \(tradingInfoDict.count) symbols")
        } catch {
            logger.error("Failed to save trading info: \(error.localizedDescription)")
        }
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
        
        let allSymbols = realTimeTrades.map { $0.trade.name }
        let now = Date()
        
        // Filter symbols that need refreshing based on cache and retry logic
        let symbolsToRefresh = allSymbols.filter { symbol in
            // Check if we have a successful fetch that's still valid
            if let lastSuccess = lastSuccessfulFetch[symbol] {
                let timeSinceSuccess = now.timeIntervalSince(lastSuccess)
                if timeSinceSuccess < cacheInterval {
                    logger.debug("Symbol \(symbol) successfully cached for \(Int(timeSinceSuccess))s, skipping refresh")
                    return false
                }
            }
            
            // Check if we have a recent failed fetch that we shouldn't retry yet
            if let lastFailure = lastFailedFetch[symbol] {
                let timeSinceFailure = now.timeIntervalSince(lastFailure)
                if timeSinceFailure < retryInterval {
                    logger.debug("Symbol \(symbol) failed \(Int(timeSinceFailure))s ago, waiting for retry interval")
                    return false
                }
            }
            
            logger.debug("Symbol \(symbol) needs refresh")
            return true
        }
        
        // Also force refresh symbols that are very old (beyond max cache age)
        let symbolsToForceRefresh = allSymbols.filter { symbol in
            guard let lastSuccess = lastSuccessfulFetch[symbol] else { return true }
            let timeSinceSuccess = now.timeIntervalSince(lastSuccess)
            return timeSinceSuccess >= maxCacheAge
        }
        
        let finalSymbolsToRefresh = Array(Set(symbolsToRefresh + symbolsToForceRefresh))
        
        if finalSymbolsToRefresh.isEmpty {
            logger.info("All \(allSymbols.count) symbols are cached or in retry cooldown, skipping network refresh")
            return
        }
        
        logger.info("About to refresh \(finalSymbolsToRefresh.count) of \(allSymbols.count) trades: \(finalSymbolsToRefresh)")

        do {
            // This now calls PythonNetworkService.fetchBatchQuotes
            let results = try await networkService.fetchBatchQuotes(for: finalSymbolsToRefresh)

            guard !results.isEmpty else {
                 logger.warning("Refresh completed but received no results from network service.")
                 return
             }

            var anySuccessfulUpdate = false
            
            // Update each trade with its corresponding result
            let resultDict: [String: StockFetchResult] = Dictionary(uniqueKeysWithValues: results.map { ($0.symbol, $0) })
            for idx in self.realTimeTrades.indices {
                let symbol = self.realTimeTrades[idx].trade.name
                if let res = resultDict[symbol] {
                    let wasSuccessful = self.realTimeTrades[idx].updateWithResult(res, retainOnFailure: true)
                    
                    // Update cache based on success/failure
                    if wasSuccessful {
                        self.lastSuccessfulFetch[symbol] = now
                        self.lastFailedFetch.removeValue(forKey: symbol) // Clear any previous failure
                        logger.debug("Updated cache for \(symbol) - successful fetch")
                        anySuccessfulUpdate = true
                    } else {
                        self.lastFailedFetch[symbol] = now
                        logger.debug("Updated failure cache for \(symbol) - failed fetch, retaining old data")
                    }
                    
                    logger.debug("Updated trade \(symbol) from refresh result.")
                } else {
                    // No result returned - treat as failure
                    self.lastFailedFetch[symbol] = now
                    logger.warning("No result returned for symbol \(symbol), treating as failure.")
                }
            }
            
            // Save trading info if any successful updates occurred
            if anySuccessfulUpdate {
                saveTradingInfo()
            }
            
            logger.info("Successfully processed \(results.count) trades of \(finalSymbolsToRefresh.count) requested.")
        } catch {
            // Mark all requested symbols as failed
            for symbol in finalSymbolsToRefresh {
                self.lastFailedFetch[symbol] = now
            }
            
            // Log the specific error from NetworkError enum if possible
            if let networkError = error as? NetworkError {
                 logger.error("Failed to refresh trades: \(networkError.localizedDescription)")
             } else {
                 logger.error("Failed to refresh trades (unknown error): \(error.localizedDescription)")
             }
        }
    }

    /// Calculates the total net gains across all trades
    func calculateNetGains() -> (amount: Double, currency: String) {
        logger.debug("Calculating net gains in \(preferredCurrency)")
        var totalGainsUSD = 0.0

        for realTimeTradeItem in realTimeTrades {
            // Ensure price is valid before calculation
            guard !realTimeTradeItem.realTimeInfo.currentPrice.isNaN,
                  realTimeTradeItem.realTimeInfo.currentPrice != 0 else {
                logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid price.")
                continue
            }

            // Ensure position cost is valid
            guard let rawCost = Double(realTimeTradeItem.trade.position.positionAvgCostString), rawCost > 0 else {
                logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid cost.")
                continue
            }

            let currentPrice = realTimeTradeItem.realTimeInfo.currentPrice
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency
            let symbol = realTimeTradeItem.trade.name
            
            // Convert avgCost to match the currency of currentPrice
            var adjustedCost = rawCost
            
            // If this is a UK stock (.L) and currency is GBP, convert avgCost from GBX to GBP
            if symbol.uppercased().hasSuffix(".L") && currency == "GBP" {
                adjustedCost = rawCost / 100.0  // Convert GBX to GBP
                logger.debug("Converted cost for \(symbol) from \(rawCost) GBX to \(adjustedCost) GBP")
            }

            // Calculate gains in the stock's currency (currentPrice and adjustedCost are now in same currency)
            let rawGains = (currentPrice - adjustedCost) * units

            // Convert to USD for aggregation
            var gainsInUSD = rawGains
            if let knownCurrency = currency {
                if knownCurrency == "GBP" {
                    gainsInUSD = currencyConverter.convert(amount: rawGains, from: "GBP", to: "USD")
                } else if knownCurrency != "USD" {
                    gainsInUSD = currencyConverter.convert(amount: rawGains, from: knownCurrency, to: "USD")
                }
                // If knownCurrency is USD, gainsInUSD remains rawGains
            } else {
                // Assume USD if currency is nil
                logger.warning("Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for gain calculation.")
                // gainsInUSD remains rawGains
            }

            logger.debug("Gain calculation for \(symbol): currentPrice=\(currentPrice), adjustedCost=\(adjustedCost), units=\(units), rawGains=\(rawGains), gainsInUSD=\(gainsInUSD)")
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

    func startStaggeredRefresh() {
        refreshTimer?.invalidate()
        currentSymbolIndex = 0
        let count = max(1, realTimeTrades.count)
        let interval = refreshInterval / Double(count)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNextSymbol()
        }
    }

    private func refreshNextSymbol() {
        guard !realTimeTrades.isEmpty else { return }
        let symbol = realTimeTrades[currentSymbolIndex].trade.name
        
        // Check cache and retry logic before making individual requests
        let now = Date()
        
        // Check if we have a successful fetch that's still valid
        if let lastSuccess = lastSuccessfulFetch[symbol] {
            let timeSinceSuccess = now.timeIntervalSince(lastSuccess)
            if timeSinceSuccess < cacheInterval {
                logger.debug("Skipping individual refresh for \(symbol) - successfully cached for \(Int(timeSinceSuccess))s")
                self.currentSymbolIndex = (self.currentSymbolIndex + 1) % self.realTimeTrades.count
                return
            }
        }
        
        // Check if we have a recent failed fetch that we shouldn't retry yet
        if let lastFailure = lastFailedFetch[symbol] {
            let timeSinceFailure = now.timeIntervalSince(lastFailure)
            if timeSinceFailure < retryInterval {
                logger.debug("Skipping individual refresh for \(symbol) - failed \(Int(timeSinceFailure))s ago, waiting for retry")
                self.currentSymbolIndex = (self.currentSymbolIndex + 1) % self.realTimeTrades.count
                return
            }
        }
        
        Task {
            do {
                let result = try await self.networkService.fetchQuote(for: symbol)
                if let index = self.realTimeTrades.firstIndex(where: { $0.trade.name == symbol }) {
                    let wasSuccessful = self.realTimeTrades[index].updateWithResult(result, retainOnFailure: true)
                    
                    // Update cache based on success/failure
                    if wasSuccessful {
                        self.lastSuccessfulFetch[symbol] = now
                        self.lastFailedFetch.removeValue(forKey: symbol)
                        self.logger.debug("Updated individual cache for \(symbol) - successful fetch")
                        
                        // Save trading info for successful individual updates
                        self.saveTradingInfo()
                    } else {
                        self.lastFailedFetch[symbol] = now
                        self.logger.debug("Updated individual failure cache for \(symbol) - failed fetch, retaining old data")
                    }
                }
            } catch {
                // Mark as failed
                self.lastFailedFetch[symbol] = now
                self.logger.debug("Individual refresh failed for \(symbol): \(error.localizedDescription)")
            }
            self.currentSymbolIndex = (self.currentSymbolIndex + 1) % self.realTimeTrades.count
        }
    }

    // MARK: - Private Methods

    // Keep setupPublishers and saveTrades as they are
    private func setupPublishers() {
        $realTimeTrades
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] trades in
                guard let self = self else { return }
                self.saveTrades(trades)
                // Also save trading info when trades change (e.g., when adding/removing stocks)
                self.saveTradingInfo()
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
    /// Returns true if the update was successful (non-NaN data), false if it failed and old data was retained
    func updateWithResult(_ result: StockFetchResult, retainOnFailure: Bool = true) -> Bool {
        // Fallback logic: treat as GBX if currency is GBX/GBp or symbol ends with .L
        var price = result.regularMarketPrice // Assumes StockFetchResult.swift defines this as non-optional
        let prevClose = result.regularMarketPreviousClose // Assumes StockFetchResult.swift defines this as non-optional
        
        // Check if this is a failed fetch (NaN values)
        let isFetchFailure = price.isNaN || prevClose.isNaN
        
        if isFetchFailure {
            Logger.shared.warning("Fetch failed for \(result.symbol) - price: \(price), prevClose: \(prevClose)")
            
            if retainOnFailure {
                // Don't update the price data, but we can update the timestamp to show when we last tried
                // Keep existing currentPrice, previousClose, prevClosePrice, currency
                Logger.shared.info("Retaining last successful data for \(result.symbol)")
                return false // Indicate failure
            } else {
                // Old behavior - update with NaN values
                Logger.shared.warning("Updating \(result.symbol) with NaN values (retainOnFailure=false)")
            }
        }

        var currency = result.currency
        let symbol = result.symbol
        var isGBX = false
        if let c = currency, c == "GBX" || c == "GBp" {
            isGBX = true
        } else if symbol.uppercased().hasSuffix(".L") && currency == nil { // Only assume .L is GBX if currency isn't specified otherwise
            isGBX = true
        }
        
        var finalPrice = price
        var finalPrevClose = prevClose

        if isGBX && !isFetchFailure {
            finalPrice = price / 100.0
            finalPrevClose = prevClose / 100.0
            currency = "GBP" // Standardize to GBP
        }

        // Only update price data if fetch was successful or retainOnFailure is false
        if !isFetchFailure || !retainOnFailure {
            self.realTimeInfo.currentPrice = finalPrice
            self.realTimeInfo.previousClose = finalPrevClose // Use the (potentially adjusted) finalPrevClose
            self.realTimeInfo.prevClosePrice = finalPrevClose // Also set the field that StockStatusBar reads
            self.realTimeInfo.currency = currency // Now always GBP for GBX/GBp or .L stocks that were converted
        }
        
        // Always update metadata (but not the last update time if we're retaining old data)
        if !isFetchFailure || !retainOnFailure {
            self.realTimeInfo.lastUpdateTime = result.regularMarketTime ?? Int(Date().timeIntervalSince1970) // Fallback to current time if nil
            self.realTimeInfo.regularMarketTime = result.regularMarketTime ?? Int(Date().timeIntervalSince1970) // Set the field that getTimeInfo() reads
        }
        
        self.realTimeInfo.exchangeTimezoneName = result.exchangeTimezoneName ?? "GMT" // Set a default timezone
        self.realTimeInfo.shortName = result.shortName ?? self.trade.name // Use symbol if name nil

        let logger = Logger.shared // Already defined in DataModel, but ok for local scope too
        
        if isFetchFailure && retainOnFailure {
            logger.info("Retained old data for \(self.trade.name): Price \(self.realTimeInfo.currentPrice) Currency: \(self.realTimeInfo.currency ?? "N/A") (fetch failed)")
        } else {
            logger.info("Updated trade \(self.trade.name): Price \(self.realTimeInfo.currentPrice) PrevClose: \(String(describing: self.realTimeInfo.previousClose)) prevClosePrice: \(self.realTimeInfo.prevClosePrice) Currency: \(self.realTimeInfo.currency ?? "N/A") isGBX: \(isGBX) originalPrice: \(price) originalPrevClose: \(prevClose) originalCurrency: \(result.currency ?? "nil")")
        }
        
        return !isFetchFailure // Return true if successful, false if failed
    }
}
