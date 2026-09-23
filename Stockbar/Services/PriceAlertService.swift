//
//  PriceAlertService.swift
//  Stockbar
//
//  Price alert monitoring and notification service
//  Tracks user-defined price thresholds and sends notifications
//  Now uses Core Data for persistence via CoreDataStack
//

import AppKit
import CoreData
import Foundation
@preconcurrency import UserNotifications

// MARK: - Alert Types
enum AlertType: String, Codable, CaseIterable {
    case price = "price"
    case portfolioMilestone = "portfolio"
    
    var displayName: String {
        switch self {
        case .price: return "Price Alert"
        case .portfolioMilestone: return "Portfolio Milestone"
        }
    }
}

// MARK: - Alert Condition Types
enum AlertCondition: String, Codable, CaseIterable {
    case above = "Above"
    case below = "Below"
    case percentChange = "% Change"

    var description: String {
        switch self {
        case .above: return "Price rises above"
        case .below: return "Price falls below"
        case .percentChange: return "Price changes by"
        }
    }
}

// MARK: - Price Alert Model (legacy for compatibility)
struct PriceAlert: Codable, Identifiable {
    let id: UUID
    let symbol: String?
    let alertType: AlertType
    let condition: AlertCondition
    let threshold: Double  // Price for above/below, percentage for percentChange
    let isEnabled: Bool
    let createdAt: Date
    var lastTriggered: Date?

    init(symbol: String?, alertType: AlertType = .price, condition: AlertCondition, threshold: Double, isEnabled: Bool = true) {
        self.id = UUID()
        self.symbol = symbol
        self.alertType = alertType
        self.condition = condition
        self.threshold = threshold
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.lastTriggered = nil
    }

    func conditionMet(currentPrice: Double, previousPrice: Double) -> Bool {
        guard isEnabled else { return false }

        switch condition {
        case .above:
            return currentPrice > threshold && previousPrice <= threshold
        case .below:
            return currentPrice < threshold && previousPrice >= threshold
        case .percentChange:
            let change = abs((currentPrice - previousPrice) / previousPrice * 100)
            return change >= abs(threshold)
        }
    }
    
    func portfolioMilestoneConditionMet(currentValue: Double, previousValue: Double) -> Bool {
        guard isEnabled, alertType == .portfolioMilestone else { return false }
        
        switch condition {
        case .above:
            return currentValue > threshold && previousValue <= threshold
        case .below:
            return currentValue < threshold && previousValue >= threshold
        case .percentChange:
            let change = abs((currentValue - previousValue) / previousValue * 100)
            return change >= abs(threshold)
        }
    }

    func formattedThreshold(currency: String) -> String {
        switch condition {
        case .above, .below:
            return String(format: "%.2f %@", threshold, currency)
        case .percentChange:
            return String(format: "%.1f%%", abs(threshold))
        }
    }
}

// MARK: - Price Alert Service
@MainActor
class PriceAlertService: ObservableObject {
    static let shared = PriceAlertService()

    @Published private(set) var alerts: [PriceAlert] = []
    
    private let coreDataStack = CoreDataStack.shared

    /// Read-only view context. All **writes** go through `performBackgroundWrite`
    /// so they never block the main thread — `checkAlerts` runs once per symbol
    /// per refresh, so a synchronous main-thread save here sat squarely in the
    /// hot path.
    private var viewContext: NSManagedObjectContext { coreDataStack.viewContext }

    /// Runs a Core Data mutation on a background context and saves it there.
    private func performBackgroundWrite(
        _ description: String,
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> Void
    ) {
        let context = coreDataStack.newBackgroundContext()
        context.perform {
            do {
                try block(context)
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                Task {
                    await Logger.shared.error("❌ Alert store write failed (\(description)): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Fetches the single AlertEntity with the given id inside `context`.
    private nonisolated static func alertEntity(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> AlertEntity? {
        let fetchRequest: NSFetchRequest<AlertEntity> = AlertEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1
        return try context.fetch(fetchRequest).first
    }

    // Track last known prices to detect threshold crossings
    private var lastKnownPrices: [String: Double] = [:]
    private var lastKnownPortfolioValue: Double = 0.0

    private init() {
        // Migrate from UserDefaults to Core Data if needed
        migrateLegacyAlerts()
        
        loadAlerts()
    }

    // MARK: - Alert Management

    func addAlert(_ alert: PriceAlert) {
        // Save to Core Data on a background context
        let snapshot = alert
        performBackgroundWrite("addAlert") { context in
            let alertEntity = AlertEntity(context: context)
            alertEntity.id = snapshot.id
            alertEntity.symbol = snapshot.symbol
            alertEntity.alertType = snapshot.alertType.rawValue
            alertEntity.condition = snapshot.condition.rawValue
            alertEntity.threshold = snapshot.threshold
            alertEntity.isEnabled = snapshot.isEnabled
            alertEntity.createdAt = snapshot.createdAt
            alertEntity.lastTriggered = snapshot.lastTriggered
        }

        alerts.append(alert)
        if alert.isEnabled {
            ensureNotificationAuthorizationIfNeeded()
        }
        Task {
            await Logger.shared.info("✅ Added alert: \(alert.alertType.displayName) for \(alert.symbol ?? "portfolio")")
        }
    }

    func removeAlert(id: UUID) {
        // Remove from Core Data on a background context
        performBackgroundWrite("removeAlert") { context in
            let fetchRequest: NSFetchRequest<AlertEntity> = AlertEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            for alert in try context.fetch(fetchRequest) {
                context.delete(alert)
            }
        }

        alerts.removeAll { $0.id == id }
        Task {
            await Logger.shared.info("Removed price alert")
        }
    }

    func toggleAlert(id: UUID) {
        guard let index = alerts.firstIndex(where: { $0.id == id }) else { return }

        let alert = alerts[index]
        let newEnabledState = !alert.isEnabled

        performBackgroundWrite("toggleAlert") { context in
            guard let alertEntity = try Self.alertEntity(id: id, in: context) else { return }
            alertEntity.isEnabled = newEnabledState
        }

        // Update in-memory alerts array
        alerts[index] = PriceAlert(
            symbol: alert.symbol,
            alertType: alert.alertType,
            condition: alert.condition,
            threshold: alert.threshold,
            isEnabled: newEnabledState
        )

        if newEnabledState {
            ensureNotificationAuthorizationIfNeeded()
        }

        Task {
            await Logger.shared.info("✅ Toggled alert \(id)")
        }
    }

    func getAlerts(for symbol: String) -> [PriceAlert] {
        alerts.filter { $0.symbol == symbol }
    }
    
    func getPortfolioMilestoneAlerts() -> [PriceAlert] {
        alerts.filter { $0.alertType == .portfolioMilestone }
    }

    // MARK: - Price Monitoring

    func checkAlerts(symbol: String, currentPrice: Double, previousPrice: Double, currency: String) {
        let symbolAlerts = getAlerts(for: symbol).filter { $0.isEnabled }

        // Get last known price or use previous close
        let lastPrice = lastKnownPrices[symbol] ?? previousPrice

        for alert in symbolAlerts {
            if alert.conditionMet(currentPrice: currentPrice, previousPrice: lastPrice) {
                // Check cooldown period (15 minutes) to avoid spam
                if let lastTriggered = alert.lastTriggered,
                   Date().timeIntervalSince(lastTriggered) < 900 {
                    continue
                }

                sendNotification(for: alert, currentPrice: currentPrice, currency: currency)
                updateLastTriggered(alertId: alert.id)
            }
        }

        // Update last known price
        lastKnownPrices[symbol] = currentPrice
    }

    // MARK: - Notifications

    private func ensureNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                if settings.authorizationStatus == .denied {
                    Task {
                        await Logger.shared.debug("Price alerts are disabled because notification permission was denied")
                    }
                }
                return
            }

            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    let notificationError = error as NSError
                    Task {
                        if notificationError.domain == UNErrorDomain,
                           notificationError.code == UNError.Code.notificationsNotAllowed.rawValue {
                            await Logger.shared.debug("Notification permission is not available for this application")
                        } else {
                            await Logger.shared.error("Notification permission error: \(error.localizedDescription)")
                        }
                    }
                } else if granted {
                    Task {
                        await Logger.shared.info("Notification permissions granted")
                    }
                }
            }
        }
    }

    private func sendNotification(for alert: PriceAlert, currentPrice: Double, currency: String) {
        let content = UNMutableNotificationContent()
        content.title = "🔔 Price Alert: \(alert.symbol ?? "Unknown")"

        let message: String
        switch alert.condition {
        case .above:
            message = "Price rose above \(alert.formattedThreshold(currency: currency)). Current: \(String(format: "%.2f %@", currentPrice, currency))"
        case .below:
            message = "Price fell below \(alert.formattedThreshold(currency: currency)). Current: \(String(format: "%.2f %@", currentPrice, currency))"
        case .percentChange:
            message = "Price changed by \(alert.formattedThreshold(currency: currency)). Current: \(String(format: "%.2f %@", currentPrice, currency))"
        }

        content.body = message
        content.sound = .default
        content.categoryIdentifier = "PRICE_ALERT"

        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil  // Send immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Task {
                    await Logger.shared.error("Failed to send notification: \(error.localizedDescription)")
                }
            } else {
                Task {
                    await Logger.shared.info("Sent price alert notification for \(alert.symbol ?? "portfolio")")
                }
            }
        }
    }

    // MARK: - Persistence

    private func loadAlerts() {
        let fetchRequest: NSFetchRequest<AlertEntity> = AlertEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \AlertEntity.createdAt, ascending: false)]
        
        do {
            let alertEntities = try viewContext.fetch(fetchRequest)
            alerts = alertEntities.compactMap { entity -> PriceAlert? in
                guard let _ = entity.id,
                      let conditionString = entity.condition,
                      let condition = AlertCondition(rawValue: conditionString),
                      let alertTypeString = entity.alertType,
                      let alertType = AlertType(rawValue: alertTypeString),
                      let _ = entity.createdAt else {
                    return nil
                }
                
                let alert = PriceAlert(
                    symbol: entity.symbol,
                    alertType: alertType,
                    condition: condition,
                    threshold: entity.threshold,
                    isEnabled: entity.isEnabled
                )
                // Use reflection to update immutable properties
                var mutableAlert = alert
                mutableAlert.lastTriggered = entity.lastTriggered
                return mutableAlert
            }
            
            Task {
                await Logger.shared.info("✅ Loaded \(alerts.count) alerts from Core Data")
            }
        } catch {
            Task {
                await Logger.shared.error("❌ Failed to load alerts: \(error.localizedDescription)")
            }
            alerts = []
        }
    }

    private func migrateLegacyAlerts() {
        // Check if legacy alerts exist in UserDefaults
        let userDefaultsKey = "priceAlerts"
        guard let data = StockbarRuntimeStorage.userDefaults.data(forKey: userDefaultsKey),
              let legacyAlerts = try? JSONDecoder().decode([PriceAlert].self, from: data) else {
            return
        }
        
        Task {
            await Logger.shared.info("📦 Migrating \(legacyAlerts.count) legacy alerts to Core Data...")
        }
        
        // This runs from init() and must finish before loadAlerts() reads the
        // store, so it is deliberately synchronous — but still on a background
        // context rather than viewContext. It is a one-time migration.
        let context = coreDataStack.newBackgroundContext()
        let migrationError: Error? = context.performAndWait {
            for alert in legacyAlerts {
                let alertEntity = AlertEntity(context: context)
                alertEntity.id = alert.id
                alertEntity.symbol = alert.symbol
                alertEntity.alertType = alert.alertType.rawValue
                alertEntity.condition = alert.condition.rawValue
                alertEntity.threshold = alert.threshold
                alertEntity.isEnabled = alert.isEnabled
                alertEntity.createdAt = alert.createdAt
                alertEntity.lastTriggered = alert.lastTriggered
            }

            do {
                try context.save()
                return nil
            } catch {
                return error
            }
        }

        if let migrationError {
            Task {
                await Logger.shared.error("❌ Failed to migrate alerts: \(migrationError.localizedDescription)")
            }
            return
        }

        // Remove from UserDefaults only after a successful migration
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: userDefaultsKey)
        Task {
            await Logger.shared.info("✅ Successfully migrated \(legacyAlerts.count) alerts to Core Data")
        }
    }

    private func updateLastTriggered(alertId: UUID) {
        // Reached from checkAlerts() once per symbol per refresh, so this must
        // not save synchronously on the main thread.
        let triggeredAt = Date()

        performBackgroundWrite("updateLastTriggered") { context in
            guard let alertEntity = try Self.alertEntity(id: alertId, in: context) else { return }
            alertEntity.lastTriggered = triggeredAt
        }

        // Update in-memory alerts array
        guard let index = alerts.firstIndex(where: { $0.id == alertId }) else { return }
        let alert = alerts[index]
        var mutableAlert = PriceAlert(
            symbol: alert.symbol,
            alertType: alert.alertType,
            condition: alert.condition,
            threshold: alert.threshold,
            isEnabled: alert.isEnabled
        )
        mutableAlert.lastTriggered = triggeredAt
        alerts[index] = mutableAlert
    }
    
    // MARK: - Portfolio Milestone Checking
    
    func checkPortfolioMilestones(currentValue: Double, previousValue: Double, currency: String) {
        let portfolioAlerts = alerts.filter { $0.alertType == .portfolioMilestone && $0.isEnabled }
        
        for alert in portfolioAlerts {
            if alert.portfolioMilestoneConditionMet(currentValue: currentValue, previousValue: lastKnownPortfolioValue) {
                // Check cooldown period (15 minutes) to avoid spam
                if let lastTriggered = alert.lastTriggered,
                   Date().timeIntervalSince(lastTriggered) < 900 {
                    continue
                }
                
                sendPortfolioMilestoneNotification(for: alert, currentValue: currentValue, currency: currency)
                updateLastTriggered(alertId: alert.id)
            }
        }
        
        // Update last known portfolio value
        lastKnownPortfolioValue = currentValue
    }
    
    private func sendPortfolioMilestoneNotification(for alert: PriceAlert, currentValue: Double, currency: String) {
        let content = UNMutableNotificationContent()
        content.title = "📊 Portfolio Milestone Alert"
        
        let message: String
        switch alert.condition {
        case .above:
            message = "Portfolio value rose above \(alert.formattedThreshold(currency: currency)). Current: \(String(format: "%.2f %@", currentValue, currency))"
        case .below:
            message = "Portfolio value fell below \(alert.formattedThreshold(currency: currency)). Current: \(String(format: "%.2f %@", currentValue, currency))"
        case .percentChange:
            message = "Portfolio value changed by \(alert.formattedThreshold(currency: currency)). Current: \(String(format: "%.2f %@", currentValue, currency))"
        }
        
        content.body = message
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Task {
                    await Logger.shared.error("Failed to send portfolio milestone notification: \(error.localizedDescription)")
                }
            } else {
                Task {
                    await Logger.shared.info("📊 Portfolio milestone notification sent: \(message)")
                }
            }
        }
    }
}
