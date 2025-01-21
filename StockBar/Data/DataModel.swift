import Combine
import Foundation

class DataModel: ObservableObject {
    static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"]

    // MARK: - Properties

    private let networkService: NetworkService
    private let currencyConverter: CurrencyConverter
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var cancellables = Set<AnyCancellable>()

    @Published var realTimeTrades: [RealTimeTrade]
    @Published var showColorCoding: Bool {
        didSet {
            UserDefaults.standard.set(showColorCoding, forKey: "showColorCoding")
        }
    }
    @Published var preferredCurrency: String {
        didSet {
            UserDefaults.standard.set(preferredCurrency, forKey: "preferredCurrency")
        }
    }

    // MARK: - Initialization

    init(networkService: NetworkService = YahooFinanceService(),
         currencyConverter: CurrencyConverter = CurrencyConverter()) {
        self.networkService = networkService
        self.currencyConverter = currencyConverter

        self.preferredCurrency = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "USD"
        self.showColorCoding = UserDefaults.standard.bool(forKey: "showColorCoding")

        let data = UserDefaults.standard.object(forKey: "usertrades") as? Data ?? Data()
        self.realTimeTrades = ((try? decoder.decode([Trade].self, from: data)) ?? emptyTrades(size: 1))
            .map { RealTimeTrade(trade: $0) }

        setupPublishers()
        Logger.shared.log(.info, "DataModel initialized with \(realTimeTrades.count) trades")
    }

    // MARK: - Public Methods

    /// Refreshes all stock data from the network
    func refreshAllTrades() async {
        Logger.shared.log(.info, "Starting refresh for all trades")
        let symbols = realTimeTrades.map { $0.trade.name }

        do {
            let results = try await networkService.fetchBatchQuotes(for: symbols)

            // Update each trade with its corresponding result
            for result in results {
                if let index = realTimeTrades.firstIndex(where: { $0.trade.name == result.symbol }) {
                    DispatchQueue.main.async {
                        self.realTimeTrades[index].updateWithResult(result)
                    }
                }
            }
            Logger.shared.log(.info, "Successfully refreshed \(results.count) trades")
        } catch {
            Logger.shared.log(.error, "Failed to refresh trades: \(error.localizedDescription)")
        }
    }

    /// Calculates the total net gains across all trades
    func calculateNetGains() -> (amount: Double, currency: String) {
        Logger.shared.log(.debug, "Calculating net gains in \(preferredCurrency)")
        var totalGainsUSD = 0.0

        for trade in realTimeTrades {
            guard !trade.currentPrice.isNaN else { continue }

            let rawPrice = trade.currentPrice
            let rawCost = Double(trade.trade.position.positionAvgCostString) ?? 0.0
            let units = trade.trade.position.unitSize
            let currency = trade.currency

            // Calculate raw gains in original currency
            let rawGains = (rawPrice - rawCost) * units

            // Convert to USD
            var gainsInUSD = rawGains
            if currency == "GBX" || currency == "GBp" {
                let gbpAmount = rawGains / 100.0
                gainsInUSD = currencyConverter.convert(amount: gbpAmount, from: "GBP", to: "USD")
            } else if let currency = currency {
                gainsInUSD = currencyConverter.convert(amount: rawGains, from: currency, to: "USD")
            }

            totalGainsUSD += gainsInUSD
        }

        // Convert final total to preferred currency
        var finalAmount = totalGainsUSD
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0
        } else {
            finalAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: preferredCurrency)
        }

        Logger.shared.log(.debug, "Net gains calculated: \(finalAmount) \(preferredCurrency)")
        return (finalAmount, preferredCurrency)
    }

    // MARK: - Private Methods

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
        Logger.shared.log(.debug, "Saving \(trades.count) trades to UserDefaults")
        do {
            let tradesData = try encoder.encode(trades.map { $0.trade })
            UserDefaults.standard.set(tradesData, forKey: "usertrades")
        } catch {
            Logger.shared.log(.error, "Failed to save trades: \(error.localizedDescription)")
        }
    }
}

// MARK: - RealTimeTrade Extension

extension RealTimeTrade {
    /// Updates the trade with new data from the Yahoo Finance API
    func updateWithResult(_ result: Result) {
        self.currentPrice = result.regularMarketPrice
        self.previousClose = result.regularMarketPreviousClose
        self.currency = result.currency
        self.lastUpdateTime = result.regularMarketTime
        self.shortName = result.shortName

        Logger.shared.log(.debug, "Updated trade \(trade.name): Price \(currentPrice) \(currency ?? "Unknown")")
    }
}
