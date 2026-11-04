import Combine
import Foundation

// Structure to store historical rate data
public struct CurrencyRateSnapshot: Codable, Sendable {
    let timestamp: Date
    let rates: [String: Double]
    let baseCurrency: String
}

public final class CurrencyConverter: ObservableObject, @unchecked Sendable {
    public static let shared = CurrencyConverter()

    @Published public var exchangeRates: [String: Double] = [:] {
        didSet { storeRateState() }
    }
    @Published public var lastRefreshTime: Date = Date.distantPast
    @Published public var lastRefreshSuccess: Bool = false
    @Published private(set) var sourceStatus: FolyncSupplementalSourceStatus = .legacy {
        didSet { storeRateState() }
    }

    /// `convert` runs on background calculation tasks while the main thread
    /// replaces the rates, so it reads this lock-protected copy instead of the
    /// published dictionary (a data race otherwise).
    private let rateStateLock = NSLock()
    private var lockedRates: [String: Double] = [:]
    private var lockedSourceStatus: FolyncSupplementalSourceStatus = .legacy
    private var periodicRefreshTimer: Timer?

    /// Rates older than this are labelled stale rather than live.
    static let staleRateAge: TimeInterval = 24 * 3_600

    private func storeRateState() {
        rateStateLock.lock()
        lockedRates = exchangeRates
        lockedSourceStatus = sourceStatus
        rateStateLock.unlock()
    }

    private func rateState() -> (rates: [String: Double], status: FolyncSupplementalSourceStatus) {
        rateStateLock.lock()
        defer { rateStateLock.unlock() }
        return (lockedRates, lockedSourceStatus)
    }

    /// True when the last successful fetch is older than `staleRateAge`.
    public func ratesAreStale(now: Date = Date()) -> Bool {
        lastRefreshTime != .distantPast && now.timeIntervalSince(lastRefreshTime) > Self.staleRateAge
    }

    /// True once any conversion has had to fall back to the hard-coded
    /// approximate rates below. Surfaced in the UI so a portfolio total computed
    /// from stale constants is never presented as if it were a live figure.
    @Published public private(set) var isUsingFallbackRates: Bool = false
    private let baseURL = "https://api.exchangerate-api.com/v4/latest/USD"
    private let refreshCooldown: TimeInterval = 300 // 5 minutes minimum between refreshes
    /// Throttle marker for refresh attempts. Kept separate from
    /// `lastRefreshTime`, which must only describe when the rates in use were
    /// actually obtained — a failed attempt must not read as "Just now".
    private var lastRefreshAttemptTime: Date = .distantPast
    private let supplementalRouter: any FolyncSupplementalFXRouting
    private let legacyRefreshObserver: (@Sendable () -> Void)?
    private let defaults: UserDefaults
    private let providerPolicy: StockbarProviderAccessPolicy
    private var folyncOverlayBaseline: (rates: [String: Double], refreshTime: Date, success: Bool)?
    
    // Currency history tracking (keep last 30 days)
    private var rateHistory: [CurrencyRateSnapshot] = []
    private let maxHistoryDays: Int = 30
    private let significantChangeThreshold: Double = 0.02 // 2% change threshold for alerts
    
    // Alert tracking to prevent spam
    private var lastAlertTimestamps: [String: Date] = [:] // currency pair -> last alert time
    private let alertCooldown: TimeInterval = 3600 // 1 hour between alerts for same pair

    public init(
        exchangeRates: [String: Double] = [:],
        refreshOnInit: Bool = true,
        loadHistoryOnInit: Bool = true,
        defaults: UserDefaults = StockbarRuntimeStorage.userDefaults
    ) {
        self.exchangeRates = exchangeRates
        self.supplementalRouter = FolyncSupplementalCoordinator.shared
        self.legacyRefreshObserver = nil
        self.defaults = defaults
        self.providerPolicy = .current
        finishInitialization(
            exchangeRates: exchangeRates,
            refreshOnInit: refreshOnInit,
            loadHistoryOnInit: loadHistoryOnInit
        )
    }

    init(
        exchangeRates: [String: Double] = [:],
        refreshOnInit: Bool = true,
        loadHistoryOnInit: Bool = true,
        supplementalRouter: any FolyncSupplementalFXRouting,
        legacyRefreshObserver: (@Sendable () -> Void)? = nil,
        defaults: UserDefaults = StockbarRuntimeStorage.userDefaults,
        providerPolicy: StockbarProviderAccessPolicy = .current
    ) {
        self.exchangeRates = exchangeRates
        self.supplementalRouter = supplementalRouter
        self.legacyRefreshObserver = legacyRefreshObserver
        self.defaults = defaults
        self.providerPolicy = providerPolicy
        finishInitialization(
            exchangeRates: exchangeRates,
            refreshOnInit: refreshOnInit,
            loadHistoryOnInit: loadHistoryOnInit
        )
    }

    private func finishInitialization(
        exchangeRates: [String: Double],
        refreshOnInit: Bool,
        loadHistoryOnInit: Bool
    ) {
        if !exchangeRates.isEmpty {
            lastRefreshTime = Date()
            lastRefreshSuccess = true
        }

        storeRateState()
        if loadHistoryOnInit {
            loadRateHistory()
        }
        if refreshOnInit {
            refreshRates()
            // Rates were fetched only at launch, so a long-running menu-bar
            // session kept converting with launch-day rates.
            let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
                self?.refreshRates()
            }
            timer.tolerance = 300
            RunLoop.main.add(timer, forMode: .common)
            periodicRefreshTimer = timer
        }
    }

    // Get exchange rate with metadata for UI display
    public func getExchangeRateInfo(from: String, to: String) -> (rate: Double, timestamp: Date, isFallback: Bool) {
        let sourceIsPence = Self.isPenceCurrency(from)
        let targetIsPence = Self.isPenceCurrency(to)
        let sourceCurrency = sourceIsPence ? "GBP" : Self.normalizedCurrencyCode(from)
        let targetCurrency = targetIsPence ? "GBP" : Self.normalizedCurrencyCode(to)

        if sourceIsPence && targetIsPence {
            return (1.0, lastRefreshTime, false)
        }
        if sourceCurrency == targetCurrency {
            let scale = (sourceIsPence ? 0.01 : 1) * (targetIsPence ? 100 : 1)
            return (scale, lastRefreshTime, false)
        }

        // Determine if we're using fallback rates
        let usingFallback = exchangeRates.isEmpty || lastRefreshTime == Date.distantPast

        // Calculate rate
        let normalizedRate: Double
        if sourceCurrency == "USD" {
            guard let resolved = exchangeRates[targetCurrency] ?? legacyFallbackRate(to: targetCurrency) else {
                return (.nan, lastRefreshTime, false)
            }
            normalizedRate = resolved
        } else if targetCurrency == "USD" {
            guard let sourceRate = exchangeRates[sourceCurrency] ?? legacyFallbackRate(to: sourceCurrency) else {
                return (.nan, lastRefreshTime, false)
            }
            normalizedRate = 1.0 / sourceRate
        } else {
            guard let sourceRate = exchangeRates[sourceCurrency] ?? legacyFallbackRate(to: sourceCurrency),
                  let targetRate = exchangeRates[targetCurrency] ?? legacyFallbackRate(to: targetCurrency) else {
                return (.nan, lastRefreshTime, false)
            }
            normalizedRate = targetRate / sourceRate
        }

        let rate = normalizedRate * (sourceIsPence ? 0.01 : 1) * (targetIsPence ? 100 : 1)
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

    public func refreshRates(force: Bool = false) {
        Task { [weak self] in
            await self?.refreshRatesFromConfiguredSource(force: force)
        }
    }

    func refreshRatesFromConfiguredSource(force: Bool = false) async {
        // Throttle refresh requests to prevent excessive API calls
        let now = Date()
        let timeSinceLastRefresh = now.timeIntervalSince(max(lastRefreshTime, lastRefreshAttemptTime))

        guard force || timeSinceLastRefresh >= refreshCooldown else {
            Task { await Logger.shared.debug("💱 [CurrencyConverter] Skipping refresh - last refresh was \(Int(timeSinceLastRefresh))s ago") }
            return
        }

        let preRouteBaseline = (
            rates: exchangeRates,
            refreshTime: lastRefreshTime,
            success: lastRefreshSuccess
        )
        setRateRefreshInFlight(true)
        await MainActor.run { self.lastRefreshAttemptTime = now }
        switch await supplementalRouter.routeFX() {
        case .folync(let rates, let asOf, let status):
            await MainActor.run {
                if self.folyncOverlayBaseline == nil {
                    self.folyncOverlayBaseline = preRouteBaseline
                } else {
                    self.checkForSignificantChanges(newRates: rates)
                }
                self.exchangeRates = rates
                self.lastRefreshTime = asOf ?? now
                self.lastRefreshSuccess = true
                self.sourceStatus = status
                self.clearFallbackUsage()
            }
            setRateRefreshInFlight(false)
            await Logger.shared.info("💱 [CurrencyConverter] Using Folync USD-base rates (\(status.label))")
        case .legacy:
            await deactivateFolyncOverlay()
            refreshLegacyRates()
        case .unavailable:
            await MainActor.run {
                if self.folyncOverlayBaseline == nil {
                    self.folyncOverlayBaseline = preRouteBaseline
                }
                self.exchangeRates = [:]
                self.lastRefreshSuccess = false
                self.sourceStatus = .unavailable
            }
            setRateRefreshInFlight(false)
            await Logger.shared.warning(
                "💱 [CurrencyConverter] Folync FX is unavailable and legacy fallback is disabled"
            )
        }
    }

    @MainActor
    func deactivateFolyncOverlay() {
        guard let baseline = folyncOverlayBaseline else {
            sourceStatus = .legacy
            return
        }
        exchangeRates = baseline.rates
        lastRefreshTime = baseline.refreshTime
        lastRefreshSuccess = baseline.success
        sourceStatus = .legacy
        folyncOverlayBaseline = nil
    }

    private func refreshLegacyRates() {
        do {
            try providerPolicy.authorize(.directFX)
        } catch {
            Task { await Logger.shared.warning("💱 [CurrencyConverter] Direct FX request blocked: \(error.localizedDescription)") }
            Task { @MainActor [weak self] in
                self?.lastRefreshSuccess = false
                self?.sourceStatus = .unavailable
            }
            setRateRefreshInFlight(false)
            return
        }
        legacyRefreshObserver?()
        guard let url = URL(string: baseURL) else {
            setRateRefreshInFlight(false)
            return
        }
        Task { await Logger.shared.info("💱 [CurrencyConverter] Fetching exchange rates from legacy API...") }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(ExchangeRateResponse.self, from: data) else {
                Task { await Logger.shared.warning("💱 [CurrencyConverter] ❌ Failed to fetch exchange rates, using fallback rates") }
                Task { @MainActor [weak self] in
                    _ = self?.activateLatestHistoricalRatesIfAvailable()
                    self?.lastRefreshSuccess = false
                    self?.sourceStatus = .legacy
                    self?.setRateRefreshInFlight(false)
                }
                return
            }

            Task { @MainActor [weak self] in
                // Check for significant changes before updating
                self?.checkForSignificantChanges(newRates: response.rates)
                
                self?.exchangeRates = response.rates
                self?.lastRefreshTime = Date()
                self?.lastRefreshSuccess = true
                self?.sourceStatus = .legacy
                self?.setRateRefreshInFlight(false)
                self?.clearFallbackUsage()

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
        let snapshotCount = rateHistory.count
        Task { await Logger.shared.debug("💱 [CurrencyConverter] Saved rate history. Total snapshots: \(snapshotCount)") }
    }
    
    private func saveRateHistory() {
        if let encoded = try? JSONEncoder().encode(rateHistory) {
            defaults.set(encoded, forKey: "currencyRateHistory")
        }
    }
    
    private func loadRateHistory() {
        if let data = defaults.data(forKey: "currencyRateHistory"),
           let history = try? JSONDecoder().decode([CurrencyRateSnapshot].self, from: data) {
            rateHistory = history
            let snapshotCount = history.count
            Task { await Logger.shared.info("💱 [CurrencyConverter] Loaded \(snapshotCount) historical rate snapshots") }
        }
    }

    @discardableResult
    func activateLatestHistoricalRatesIfAvailable() -> Bool {
        guard exchangeRates.isEmpty || lastRefreshTime == Date.distantPast else {
            return false
        }
        guard let latest = rateHistory
            .filter({ $0.baseCurrency.uppercased() == "USD" && !$0.rates.isEmpty })
            .max(by: { $0.timestamp < $1.timestamp }) else {
            return false
        }

        exchangeRates = latest.rates
        lastRefreshTime = latest.timestamp
        Task {
            await Logger.shared.warning("💱 [CurrencyConverter] Using latest saved historical exchange rates after live fetch failed.")
        }
        return true
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
            
            await StockbarNotificationPoster.post(
                title: "Significant Exchange Rate Change",
                body: "USD/\(currency) has \(direction) by \(changePercentFormatted) (\(String(format: "%.4f", oldRate)) → \(String(format: "%.4f", newRate)))"
            )
        }
    }

    public func convert(amount: Double, from: String, to: String) -> Double {
        // Minor units (pence GBp/GBX, South African cents ZAc, Israeli agorot ILA)
        // convert through their major currency at 1/100.
        let sourceMinor = Self.minorUnitMajorCurrency(from)
        let targetMinor = Self.minorUnitMajorCurrency(to)
        if let sourceMinor, sourceMinor == targetMinor {
            return amount
        }
        if let sourceMinor {
            return convert(amount: amount / 100, from: sourceMinor, to: to)
        }
        if let targetMinor {
            return convert(amount: amount, from: from, to: targetMinor) * 100
        }
        let sourceCurrency = Self.normalizedCurrencyCode(from)
        let targetCurrency = Self.normalizedCurrencyCode(to)
        let (exchangeRates, sourceStatus) = rateState()

        // If same currency, return original amount
        if sourceCurrency == targetCurrency {
            return amount
        }
        
        logDebug("Converting \(amount) from \(sourceCurrency) to \(targetCurrency)")
        
        // Handle USD as base currency (API uses USD as base)
        if sourceCurrency == "USD" {
            guard let targetRate = exchangeRates[targetCurrency] else {
                guard sourceStatus == .legacy else {
                    logDebug("Folync rate missing for \(targetCurrency); refusing hard-coded source mixing")
                    return .nan
                }
                // Fallback rates if API fails
                guard let fallbackRate = getFallbackRate(to: targetCurrency) else {
                    return unconvertedAmount(amount, detail: targetCurrency)
                }
                noteFallbackUsage("USD→\(targetCurrency)")
                let result = amount * fallbackRate
                logDebug("Using FALLBACK rate: \(amount) USD × \(fallbackRate) = \(result) \(targetCurrency)")
                return result
            }
            let result = amount * targetRate
            logDebug("Using API rate: \(amount) USD × \(targetRate) = \(result) \(targetCurrency)")
            return result
        } else if targetCurrency == "USD" {
            guard let sourceRate = exchangeRates[sourceCurrency] else {
                guard sourceStatus == .legacy else {
                    logDebug("Folync rate missing for \(sourceCurrency); refusing hard-coded source mixing")
                    return .nan
                }
                // Fallback rates if API fails
                guard let fallbackRate = getFallbackRate(to: sourceCurrency), fallbackRate != 0 else {
                    return unconvertedAmount(amount, detail: sourceCurrency)
                }
                noteFallbackUsage("\(sourceCurrency)→USD")
                let result = amount / fallbackRate
                logDebug("Using FALLBACK rate: \(amount) \(sourceCurrency) ÷ \(fallbackRate) = \(result) USD")
                return result
            }
            let result = amount / sourceRate
            logDebug("Using API rate: \(amount) \(sourceCurrency) ÷ \(sourceRate) = \(result) USD")
            return result
        } else {
            // Convert from source to USD, then USD to target
            guard let sourceRate = exchangeRates[sourceCurrency],
                  let targetRate = exchangeRates[targetCurrency] else {
                guard sourceStatus == .legacy else {
                    logDebug("Folync cross-rate is incomplete; refusing hard-coded source mixing")
                    return .nan
                }
                // Fallback conversion
                guard let fallbackFromRate = getFallbackRate(to: sourceCurrency),
                      let fallbackToRate = getFallbackRate(to: targetCurrency),
                      fallbackFromRate != 0 else {
                    return unconvertedAmount(amount, detail: "\(sourceCurrency)→\(targetCurrency)")
                }
                noteFallbackUsage("\(sourceCurrency)→\(targetCurrency)")
                let usdAmount = amount / fallbackFromRate
                let result = usdAmount * fallbackToRate
                logDebug("Using FALLBACK rates: \(amount) \(sourceCurrency) ÷ \(fallbackFromRate) × \(fallbackToRate) = \(result) \(targetCurrency)")
                return result
            }
            let amountInUSD = amount / sourceRate
            let result = amountInUSD * targetRate
            logDebug("Using API rates: \(amount) \(sourceCurrency) ÷ \(sourceRate) × \(targetRate) = \(result) \(targetCurrency)")
            return result
        }
    }

    private func logDebug(_ message: String) {
        guard Logger.isDebugLoggingEnabled else { return }
        Task { await Logger.shared.debug("💱 [CurrencyConverter] \(message)") }
    }

    private static func normalizedCurrencyCode(_ currency: String) -> String {
        currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The major currency for a 1/100 minor-unit code, or nil.
    static func minorUnitMajorCurrency(_ currency: String) -> String? {
        if isPenceCurrency(currency) { return "GBP" }
        switch currency.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ZAc", "ZAC": return "ZAR"
        case "ILA": return "ILS"
        default: return nil
        }
    }

    static func isPenceCurrency(_ currency: String) -> Bool {
        let trimmed = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "GBp" || trimmed.uppercased() == "GBX"
    }
    
    /// Last-resort approximate USD-base rates, used only when a live fetch has
    /// failed **and** no saved rate history exists (i.e. a fresh install that has
    /// never been online). These are order-of-magnitude anchors, not accurate
    /// quotes — any conversion that uses them sets `isUsingFallbackRates`, and
    /// the UI must show that the figure is approximate.
    ///
    /// Prefer `activateLatestHistoricalRatesIfAvailable()`, which replays real
    /// previously-fetched rates, over these constants.
    ///
    /// Returns nil for unrecognised currencies: converting at an invented 1:1
    /// rate silently produces a wrong portfolio value, which is worse than
    /// refusing to display a number at all.
    static let fallbackRateReferenceDate = "2026-07"

    private func getFallbackRate(to currency: String) -> Double? {
        switch currency {
        case "USD": return 1.0
        case "GBP": return 0.74   // approx. 1 USD = 0.74 GBP
        case "EUR": return 0.86   // approx. 1 USD = 0.86 EUR
        case "JPY": return 148.0  // approx. 1 USD = 148 JPY
        case "CAD": return 1.37   // approx. 1 USD = 1.37 CAD
        case "AUD": return 1.52   // approx. 1 USD = 1.52 AUD
        default: return nil
        }
    }

    private let fallbackNoticeLock = NSLock()
    private var hasNotedFallback = false
    private var rateRefreshInFlight = false

    private func setRateRefreshInFlight(_ inFlight: Bool) {
        fallbackNoticeLock.lock()
        rateRefreshInFlight = inFlight
        fallbackNoticeLock.unlock()
    }

    /// Records that a conversion could not use a live rate. `convert` runs on
    /// every render, so this latches on the first occurrence rather than
    /// dispatching a task per call.
    private func noteFallbackUsage(_ detail: String) {
        // Conversions run during startup before the first rate fetch has
        // finished. That is an unfinished state, not a degraded one, so don't
        // flash the "rates unavailable" banner while a refresh is still in
        // flight or has not been attempted at all.
        guard lastRefreshTime != Date.distantPast else { return }

        fallbackNoticeLock.lock()
        let inFlight = rateRefreshInFlight
        let alreadyNoted = hasNotedFallback
        if !inFlight { hasNotedFallback = true }
        fallbackNoticeLock.unlock()
        guard !inFlight, !alreadyNoted else { return }

        Task { @MainActor [weak self] in
            self?.isUsingFallbackRates = true
            await Logger.shared.warning(
                "💱 [CurrencyConverter] Live exchange rates unavailable (\(detail)). " +
                "Displayed values are estimates until a refresh succeeds."
            )
        }
    }

    /// Handles a currency Stockbar has no rate for at all (an unrecognised or
    /// empty code). The amount passes through unchanged — returning NaN here
    /// would poison every downstream portfolio total for what is really a
    /// data-quality problem — but the fallback flag is raised so the UI shows
    /// the value is not a converted figure.
    private func unconvertedAmount(_ amount: Double, detail: String) -> Double {
        logDebug("No rate available for \(detail); returning the amount unconverted")
        noteFallbackUsage("unsupported currency \(detail)")
        return amount
    }

    /// Clears the fallback flag once real rates are in hand again.
    private func clearFallbackUsage() {
        fallbackNoticeLock.lock()
        hasNotedFallback = false
        fallbackNoticeLock.unlock()

        if isUsingFallbackRates {
            isUsingFallbackRates = false
        }
    }

    private func legacyFallbackRate(to currency: String) -> Double? {
        sourceStatus == .legacy ? getFallbackRate(to: currency) : nil
    }
}

// Response model for the API
private struct ExchangeRateResponse: Codable {
    let rates: [String: Double]
}
