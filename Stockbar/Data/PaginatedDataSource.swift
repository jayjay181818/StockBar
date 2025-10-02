import Foundation
import Combine

/// Paginated data source for memory-efficient loading of large datasets
class PaginatedDataSource<T>: ObservableObject {
    @Published var items: [T] = []
    @Published var isLoading = false
    @Published var hasMore = true
    
    private let pageSize: Int
    private let loadPage: (Int, Int) async throws -> [T]
    private var currentPage = 0
    private let logger = Logger.shared
    
    init(pageSize: Int = 100, loadPage: @escaping (Int, Int) async throws -> [T]) {
        self.pageSize = pageSize
        self.loadPage = loadPage
    }
    
    func loadInitialData() async {
        await MainActor.run {
            items.removeAll()
            currentPage = 0
            hasMore = true
        }
        await loadNextPage()
    }
    
    func loadNextPage() async {
        guard !isLoading && hasMore else { return }
        
        await MainActor.run {
            isLoading = true
        }
        
        do {
            let offset = currentPage * pageSize
            let newItems = try await loadPage(offset, pageSize)
            
            await MainActor.run {
                self.items.append(contentsOf: newItems)
                self.currentPage += 1
                self.hasMore = newItems.count == self.pageSize
                self.isLoading = false
            }
            
            await logger.debug("Loaded page \(currentPage) with \(newItems.count) items")
        } catch {
            await MainActor.run {
                self.isLoading = false
            }
            await logger.error("Failed to load page \(currentPage): \(error)")
        }
    }
    
    func refresh() async {
        await loadInitialData()
    }
}

/// Memory-efficient historical data manager that loads data on demand
@MainActor
class OptimizedHistoricalDataProvider: ObservableObject {
    @Published var priceSnapshots: [String: PaginatedDataSource<PriceSnapshot>] = [:]
    @Published var portfolioSnapshots: PaginatedDataSource<HistoricalPortfolioSnapshot>
    
    private let historicalDataService: HistoricalDataServiceProtocol
    private let logger = Logger.shared
    
    init(historicalDataService: HistoricalDataServiceProtocol = CoreDataHistoricalDataService()) {
        self.historicalDataService = historicalDataService
        
        // Initialize portfolio snapshots
        self.portfolioSnapshots = PaginatedDataSource<HistoricalPortfolioSnapshot>(pageSize: 200) { offset, limit in
            // For portfolio snapshots, we'll load all and then paginate in memory
            let allSnapshots = try await historicalDataService.fetchAllPortfolioSnapshots()
            let endIndex = min(offset + limit, allSnapshots.count)
            guard offset < allSnapshots.count else { return [] }
            return Array(allSnapshots[offset..<endIndex])
        }
    }
    
    func getPriceDataSource(for symbol: String) -> PaginatedDataSource<PriceSnapshot> {
        if let existing = priceSnapshots[symbol] {
            return existing
        }
        
        let dataSource = PaginatedDataSource<PriceSnapshot>(pageSize: 500) { [weak self] offset, limit in
            guard let self = self else { return [] }
            return try await self.historicalDataService.fetchPriceSnapshotsPaginated(
                for: symbol,
                from: Date.distantPast,
                to: Date(),
                offset: offset,
                limit: limit
            )
        }
        
        priceSnapshots[symbol] = dataSource
        return dataSource
    }
    
    func getRecentPriceSnapshots(for symbol: String, days: Int = 30) async -> [PriceSnapshot] {
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        
        do {
            return try await historicalDataService.fetchPriceSnapshots(
                for: symbol,
                from: startDate,
                to: Date()
            )
        } catch {
            await logger.error("Failed to load recent price snapshots for \(symbol): \(error)")
            return []
        }
    }
    
    func getPortfolioSnapshots(for timeRange: ChartTimeRange) async -> [HistoricalPortfolioSnapshot] {
        let startDate = timeRange.startDate()
        
        do {
            return try await historicalDataService.fetchPortfolioSnapshots(
                from: startDate,
                to: Date()
            )
        } catch {
            await logger.error("Failed to load portfolio snapshots for \(timeRange): \(error)")
            return []
        }
    }
    
    func preloadRecentData(for symbols: [String]) async {
        await logger.info("Preloading recent data for \(symbols.count) symbols")
        
        // Load recent data (last 30 days) for each symbol to prime the cache
        await withTaskGroup(of: Void.self) { group in
            for symbol in symbols {
                group.addTask {
                    let dataSource = await self.getPriceDataSource(for: symbol)
                    await dataSource.loadInitialData()
                }
            }
        }
        
        // Load recent portfolio data
        await portfolioSnapshots.loadInitialData()
        
        await logger.info("Completed preloading recent data")
    }
    
    func clearMemoryCache() {
        priceSnapshots.removeAll()
        Task {
            await logger.info("Cleared memory cache for price snapshots")
        }
    }
}

// MARK: - Chart Time Range Extension

extension ChartTimeRange {
    func startDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: now) ?? now
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all:
            return calendar.date(byAdding: .year, value: -10, to: now) ?? now
        case .custom:
            // Custom range handled by PerformanceChartView customStartDate
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        }
    }
}