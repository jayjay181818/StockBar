//
//  UserData.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import Foundation
import Combine

// This is a single source of truth during the running of this app.
// It loads from the UserDefaults at startup and wraps the Trade with empty RealTimeTrading info.
// All the user input in preference goes here to modify Trade and then updates UserDeafults.
// All the real time trading info fetched from URLSession
// goes here to update the RealTimeTrading, then shows up on the NSStatusItem.
class DataModel : ObservableObject {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    @Published var realTimeTrades : [RealTimeTrade]
    @Published var showColorCoding: Bool = true
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let data = UserDefaults.standard.object(forKey: "usertrades") as? Data ?? Data()
        self.realTimeTrades = ((try? decoder.decode([Trade].self, from: data)) ?? emptyTrades(size: 1))
            .map {
                RealTimeTrade(trade: $0, realTimeInfo: TradingInfo())
            }
        
        // Save trades whenever they change
        $realTimeTrades
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] trades in
                guard let self = self else { return }
                let tradesData = try? self.encoder.encode(trades.map { $0.trade })
                UserDefaults.standard.set(tradesData, forKey: "usertrades")
            }
            .store(in: &cancellables)
    }
}

class RealTimeTrade : ObservableObject, Identifiable {
    let id = UUID()
    // This URL returns empty query results
    static let apiString = "https://query1.finance.yahoo.com/v6/finance/quote/?symbols=";
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
                return URLSession.shared.dataTaskPublisher(for: URL( string: (RealTimeTrade.apiString + singleTrade.name)
                                                                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! ) ??
                                                              RealTimeTrade.emptyQueryURL)
            }
            .map(\.data)
            .compactMap { try? JSONDecoder().decode(YahooFinanceQuote.self, from: $0) }
            .receive(on: DispatchQueue.main)
            .sink (
                receiveCompletion: { [weak self] _ in
                    self?.cancellable?.cancel()
                    self?.cancelled = true
                },
                receiveValue: { [weak self] yahooFinanceQuote in
                    guard let response = yahooFinanceQuote.quoteResponse else {
                        self?.realTimeInfo = TradingInfo()
                        return;
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
                            FileHandle.standardError.write(message.data(using: .utf8)!)
                            
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
                            FileHandle.standardError.write(infoMessage.data(using: .utf8)!)
                            
                            self?.realTimeInfo = newRealTimeInfo
                            // Update position currency with the one from Yahoo Finance
                            self?.trade.position.currency = currency
                            
                            let positionMessage = """
                            Position after update:
                            Currency: \(self?.trade.position.currency ?? "nil")
                            ===========================
                            """
                            FileHandle.standardError.write(positionMessage.data(using: .utf8)!)
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
        
        if let data = logMessage.data(using: .utf8) {
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
