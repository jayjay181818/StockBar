import Foundation
import CoreData

// MARK: - PriceSnapshotEntity Extensions

extension PriceSnapshotEntity {
    
    // Conversion methods
    func toPriceSnapshot() -> PriceSnapshot {
        return PriceSnapshot(
            timestamp: timestamp ?? Date(),
            price: price,
            previousClose: previousClose,
            volume: volume > 0 ? Double(volume) : nil,
            symbol: symbol ?? ""
        )
    }
    
    static func fromPriceSnapshot(_ snapshot: PriceSnapshot, in context: NSManagedObjectContext) -> PriceSnapshotEntity {
        let entity = PriceSnapshotEntity(context: context)
        entity.id = UUID()
        entity.timestamp = snapshot.timestamp
        entity.price = snapshot.price
        entity.previousClose = snapshot.previousClose
        entity.volume = Int64(snapshot.volume ?? 0)
        entity.symbol = snapshot.symbol
        return entity
    }
}

// MARK: - PositionSnapshotEntity Extensions

extension PositionSnapshotEntity {
    
    func toPositionSnapshot() -> PositionSnapshot {
        return PositionSnapshot(
            symbol: symbol ?? "",
            units: units,
            priceAtDate: priceAtDate,
            valueAtDate: valueAtDate,
            currency: currency ?? "USD"
        )
    }
    
    static func fromPositionSnapshot(_ snapshot: PositionSnapshot, in context: NSManagedObjectContext) -> PositionSnapshotEntity {
        let entity = PositionSnapshotEntity(context: context)
        entity.symbol = snapshot.symbol
        entity.units = snapshot.units
        entity.priceAtDate = snapshot.priceAtDate
        entity.valueAtDate = snapshot.valueAtDate
        entity.currency = snapshot.currency
        return entity
    }
}

// MARK: - PortfolioSnapshotEntity Extensions

extension PortfolioSnapshotEntity {
    
    func toHistoricalPortfolioSnapshot() -> HistoricalPortfolioSnapshot {
        // Note: Based on auto-generated code, this entity has a single positionSnapshot relationship
        // We'll need to restructure the data model or work with what we have
        var portfolioComposition: [String: PositionSnapshot] = [:]
        
        // Check if we have a single position snapshot
        if let position = positionSnapshot {
            portfolioComposition[position.symbol ?? ""] = position.toPositionSnapshot()
        }
        
        return HistoricalPortfolioSnapshot(
            date: timestamp ?? Date(),
            totalValue: totalValue,
            totalGains: totalGains,
            totalCost: totalCost,
            currency: currency ?? "USD",
            portfolioComposition: portfolioComposition
        )
    }
    
    static func fromHistoricalPortfolioSnapshot(_ snapshot: HistoricalPortfolioSnapshot, in context: NSManagedObjectContext) -> PortfolioSnapshotEntity {
        let entity = PortfolioSnapshotEntity(context: context)
        entity.id = snapshot.id
        entity.timestamp = snapshot.date
        entity.totalValue = snapshot.totalValue
        entity.totalGains = snapshot.totalGains
        entity.totalCost = snapshot.totalCost
        entity.currency = snapshot.currency
        entity.compositionHash = snapshot.portfolioComposition.map { "\($0.key):\($0.value.units)" }.sorted().joined(separator: ",")
        
        // For now, we'll store the first position (this needs to be restructured)
        if let firstPosition = snapshot.portfolioComposition.values.first {
            let positionEntity = PositionSnapshotEntity.fromPositionSnapshot(firstPosition, in: context)
            entity.positionSnapshot = positionEntity
        }
        
        return entity
    }
}