//
//  UserData.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import Foundation
import Combine
import SwiftUI

class DataModel : ObservableObject {
    static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"]
    private let currencyConverter = CurrencyConverter()
    
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    @Published var realTimeTrades : [RealTimeTrade]
    @Published var showColorCoding: Bool = true
    @Published var preferredCurrency: String {
        didSet {
            UserDefaults.standard.set(preferredCurrency, forKey: "preferredCurrency")
        }
    }
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.preferredCurrency = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "USD"
        
        let data = UserDefaults.standard.object(forKey: "usertrades") as? Data ?? Data()
        self.realTimeTrades = ((try? decoder.decode([Trade].self, from: data)) ?? emptyTrades(size: 1))
            .map {
                RealTimeTrade(trade: $0, realTimeInfo: TradingInfo())
            }
        
        $realTimeTrades
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] trades in
                guard let self = self else { return }
                let tradesData = try? self.encoder.encode(trades.map { $0.trade })
                UserDefaults.standard.set(tradesData, forKey: "usertrades")
            }
            .store(in: &cancellables)
    }
    
    // Calculate total net gains in preferred currency
    func calculateNetGains() -> (amount: Double, currency: String) {
        var totalGainsUSD = 0.0
        
        let debugMessage = """
        ===== STARTING NET GAINS CALCULATION =====
        Preferred Currency: \(preferredCurrency)
        Exchange Rates:
        \(currencyConverter.exchangeRates.map { "\($0.key): \($0.value) USD" }.joined(separator: "\n"))
        ========================
        
        """
        if let data = debugMessage.data(using: String.Encoding.utf8) {
            FileHandle.standardError.write(data)
        }
        
        for trade in realTimeTrades {
            guard !trade.realTimeInfo.currentPrice.isNaN else { continue }
            
            // Get raw values
            let rawPrice = trade.realTimeInfo.currentPrice
            let rawCost = Double(trade.trade.position.positionAvgCostString) ?? 0.0
            let units = trade.trade.position.unitSize
            let currency = trade.realTimeInfo.currency
            
            // Calculate raw gains in original currency
            let rawGains = (rawPrice - rawCost) * units
            
            // Convert to USD based on currency
            var gainsInUSD = rawGains
            if currency == "GBX" || currency == "GBp" {
                // Convert from pence to GBP first, then to USD
                let gbpAmount = rawGains / 100.0
                gainsInUSD = currencyConverter.convert(amount: gbpAmount, from: "GBP", to: "USD")
            } else if let currency = currency {
                gainsInUSD = currencyConverter.convert(amount: rawGains, from: currency, to: "USD")
            }
            
            totalGainsUSD += gainsInUSD
            
            let message = """
            ===== POSITION: \(trade.trade.name) =====
            Units: \(units)
            Currency: \(currency ?? "nil")
            
            Raw Values:
            Current Price: \(rawPrice)
            Average Cost: \(rawCost)
            Raw Gains: \(rawGains)
            
            USD Conversion:
            Exchange Rate: \(currency == "GBX" || currency == "GBp" ? 
                           "GBX->GBP: /100, GBP->USD: \(currencyConverter.exchangeRates["GBP"] ?? 1.0)" : 
                           "\(currency ?? "USD")->USD: \(currencyConverter.exchangeRates[currency ?? "USD"] ?? 1.0)")
            Gains in USD: \(gainsInUSD)
            Running Total USD: \(totalGainsUSD)
            ========================
            
            """
            if let data = message.data(using: String.Encoding.utf8) {
                FileHandle.standardError.write(data)
            }
        }
        
        // Convert final total from USD to preferred currency
        var finalAmount = totalGainsUSD
        
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0 // Convert GBP to pence
        } else {
            finalAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: preferredCurrency)
        }
        
        let finalMessage = """
        ===== FINAL NET GAINS =====
        Total USD: \(totalGainsUSD)
        Final Conversion:
        Rate USD->\(preferredCurrency): \(1.0 / (currencyConverter.exchangeRates[preferredCurrency] ?? 1.0))
        Total \(preferredCurrency): \(finalAmount)
        ========================
        
        """
        if let data = finalMessage.data(using: String.Encoding.utf8) {
            FileHandle.standardError.write(data)
        }
        
        return (finalAmount, preferredCurrency)
    }
}

class RealTimeTrade : ObservableObject, Identifiable {
    let id = UUID()
    static let apiString = "https://query1.finance.yahoo.com/v6/finance/quote/?symbols="
    static let emptyQueryURL = URL(string: apiString)!
    @Published var trade : Trade
    private let passThroughTrade : PassthroughSubject<Trade, Never> = PassthroughSubject()
    var sharedPassThroughTrade: Publishers.Share<PassthroughSubject<Trade, Never>>
    @Published var realTimeInfo : TradingInfo
    
    func sendTradeToPublisher() {
        if (cancelled) {
            initCancellable()
        }
        passThroughTrade.send(trade)
    }
    
    func initCancellable() {
        self.cancelled = false
        self.cancellable = sharedPassThroughTrade
            .merge(with: $trade.share()
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .removeDuplicates {
                    $0.name == $1.name
            })
            .filter {
                $0.name != ""
            }
            .setFailureType(to: URLSession.DataTaskPublisher.Failure.self)
            .flatMap { singleTrade in
                return URLSession.shared.dataTaskPublisher(for: URL(string: (RealTimeTrade.apiString + singleTrade.name)
                                                                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! ) ??
                                                              RealTimeTrade.emptyQueryURL)
            }
            .map(\.data)
            .compactMap { try? JSONDecoder().decode(YahooFinanceQuote.self, from: $0) }
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] _ in
                    self?.cancellable?.cancel()
                    self?.cancelled = true
                },
                receiveValue: { [weak self] yahooFinanceQuote in
                    guard let response = yahooFinanceQuote.quoteResponse else {
                        self?.realTimeInfo = TradingInfo()
                        return
                    }
                    
                    if let _ = response.error {
                        self?.realTimeInfo = TradingInfo()
                    }
                    else if let results = response.result {
                        if (!results.isEmpty) {
                            let currency = results[0].currency
                            let message = """
                            ===== STOCK DATA DEBUG =====
                            Yahoo Finance API Response:
                            Symbol: \(results[0].symbol)
                            Currency: \(currency ?? "nil")
                            Raw Price: \(results[0].regularMarketPrice)
                            ===========================
                            """
                            if let data = message.data(using: String.Encoding.utf8) {
                                FileHandle.standardError.write(data)
                            }
                            
                            let newRealTimeInfo = TradingInfo(currentPrice: results[0].regularMarketPrice,
                                                            prevClosePrice: results[0].regularMarketPreviousClose,
                                                            currency: currency,
                                                            regularMarketTime: results[0].regularMarketTime,
                                                            exchangeTimezoneName: results[0].exchangeTimezoneName,
                                                            shortName: results[0].shortName)
                            
                            let infoMessage = """
                            TradingInfo after conversion:
                            Currency: \(newRealTimeInfo.currency ?? "nil")
                            Price: \(newRealTimeInfo.getPrice())
                            ===========================
                            """
                            if let data = infoMessage.data(using: String.Encoding.utf8) {
                                FileHandle.standardError.write(data)
                            }
                            
                            self?.realTimeInfo = newRealTimeInfo
                            self?.trade.position.currency = currency
                            
                            let positionMessage = """
                            Position after update:
                            Currency: \(self?.trade.position.currency ?? "nil")
                            ===========================
                            """
                            if let data = positionMessage.data(using: String.Encoding.utf8) {
                                FileHandle.standardError.write(data)
                            }
                        }
                    }
                }
            )
    }
    
    init(trade: Trade, realTimeInfo: TradingInfo) {
        self.trade = trade
        self.realTimeInfo = realTimeInfo
        self.sharedPassThroughTrade = self.passThroughTrade.share()
        initCancellable()
    }
    
    var cancellable : AnyCancellable? = nil
    var cancelled : Bool = false
}

func logToFile(_ message: String) {
    if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let logPath = documentsPath.appendingPathComponent("stockbar_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "\(timestamp): \(message)\n"
        
        if let data = logMessage.data(using: String.Encoding.utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logPath) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                }
            } else {
                try? logMessage.write(to: logPath, atomically: true, encoding: .utf8)
            }
        }
    }
}

func emptyTrades(size : Int) -> [Trade]{
    return [Trade].init(repeating: Trade(name: "", position: Position(unitSize: "1", positionAvgCost: "", currency: nil)), count: size)
}

func emptyRealTimeTrade()->RealTimeTrade {
    return RealTimeTrade(trade: Trade(name: "",
                                    position: Position(unitSize: "1",
                                                     positionAvgCost: "",
                                                     currency: nil)),
                        realTimeInfo: TradingInfo())
}
