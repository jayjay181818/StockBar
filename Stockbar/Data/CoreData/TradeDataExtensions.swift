import Foundation
import CoreData

// MARK: - TradeEntity Extensions

extension TradeEntity {
    
    /// Converts Core Data entity to Trade model
    func toTrade() -> Trade {
        let position = Position(
            unitSize: unitSize ?? "1",
            positionAvgCost: positionAvgCost ?? "",
            currency: currency,
            costCurrency: costCurrency
        )

        return Trade(
            name: name ?? "",
            position: position,
            isWatchlistOnly: isWatchlistOnly
        )
    }
    
    /// Creates TradeEntity from Trade model
    static func fromTrade(_ trade: Trade, in context: NSManagedObjectContext) -> TradeEntity {
        let entity = TradeEntity(context: context)
        entity.updateFromTrade(trade)
        return entity
    }
    
    /// Updates entity properties from Trade model
    func updateFromTrade(_ trade: Trade) {
        self.name = trade.name
        self.unitSize = trade.position.unitSizeString
        self.positionAvgCost = trade.position.positionAvgCostString
        self.currency = trade.position.currency
        self.costCurrency = trade.position.costCurrency
        self.isWatchlistOnly = trade.isWatchlistOnly
        self.lastModified = Date()
    }
}

// MARK: - Position Data Handling
// Note: Position data is embedded within TradeEntity, not a separate entity

// MARK: - TradingInfoEntity Extensions

extension TradingInfoEntity {
    
    /// Converts Core Data entity to TradingInfo model
    func toTradingInfo() -> TradingInfo {
        var tradingInfo = TradingInfo()
        
        tradingInfo.currentPrice = currentPrice
        tradingInfo.previousClose = previousClose.isNaN ? nil : previousClose
        tradingInfo.lastUpdateTime = lastUpdateTime > 0 ? Int(lastUpdateTime) : nil
        tradingInfo.prevClosePrice = prevClosePrice
        tradingInfo.currency = currency
        tradingInfo.regularMarketTime = Int(regularMarketTime)
        tradingInfo.exchangeTimezoneName = exchangeTimezoneName ?? ""
        tradingInfo.shortName = shortName ?? ""
        
        // Pre/Post market data
        tradingInfo.preMarketPrice = preMarketPrice.isNaN ? nil : preMarketPrice
        tradingInfo.preMarketChange = preMarketChange.isNaN ? nil : preMarketChange
        tradingInfo.preMarketChangePercent = preMarketChangePercent.isNaN ? nil : preMarketChangePercent
        tradingInfo.preMarketTime = preMarketTime > 0 ? Int(preMarketTime) : nil
        
        tradingInfo.postMarketPrice = postMarketPrice.isNaN ? nil : postMarketPrice
        tradingInfo.postMarketChange = postMarketChange.isNaN ? nil : postMarketChange
        tradingInfo.postMarketChangePercent = postMarketChangePercent.isNaN ? nil : postMarketChangePercent
        tradingInfo.postMarketTime = postMarketTime > 0 ? Int(postMarketTime) : nil
        
        tradingInfo.marketState = marketState
        
        return tradingInfo
    }
    
    /// Creates TradingInfoEntity from TradingInfo model
    static func fromTradingInfo(_ tradingInfo: TradingInfo, symbol: String, in context: NSManagedObjectContext) -> TradingInfoEntity {
        let entity = TradingInfoEntity(context: context)
        entity.symbol = symbol
        entity.updateFromTradingInfo(tradingInfo)
        return entity
    }
    
    /// Updates entity properties from TradingInfo model
    func updateFromTradingInfo(_ tradingInfo: TradingInfo) {
        self.currentPrice = tradingInfo.currentPrice
        self.previousClose = tradingInfo.previousClose ?? Double.nan
        self.lastUpdateTime = Int64(tradingInfo.lastUpdateTime ?? 0)
        self.prevClosePrice = tradingInfo.prevClosePrice
        self.currency = tradingInfo.currency
        self.regularMarketTime = Int64(tradingInfo.regularMarketTime)
        self.exchangeTimezoneName = tradingInfo.exchangeTimezoneName
        self.shortName = tradingInfo.shortName
        
        // Pre/Post market data
        self.preMarketPrice = tradingInfo.preMarketPrice ?? Double.nan
        self.preMarketChange = tradingInfo.preMarketChange ?? Double.nan
        self.preMarketChangePercent = tradingInfo.preMarketChangePercent ?? Double.nan
        self.preMarketTime = Int64(tradingInfo.preMarketTime ?? 0)
        
        self.postMarketPrice = tradingInfo.postMarketPrice ?? Double.nan
        self.postMarketChange = tradingInfo.postMarketChange ?? Double.nan
        self.postMarketChangePercent = tradingInfo.postMarketChangePercent ?? Double.nan
        self.postMarketTime = Int64(tradingInfo.postMarketTime ?? 0)
        
        self.marketState = tradingInfo.marketState
        self.lastModified = Date()
    }
}