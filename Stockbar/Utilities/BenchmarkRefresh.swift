import Foundation

/// The benchmark's refresh workload: made-up quotes and a fixed series of
/// refresh passes, so that the refresh path can be measured without the
/// network, Python or a provider account.
///
/// Only an acceptance run with live providers off can turn it on, through the
/// environment `Scripts/perf/benchmark.sh --refresh` sets. Until the benchmark
/// sends the app SIGUSR1, every quote is refused exactly as in any acceptance
/// run, so the launch and the idle window are measured as before.
struct BenchmarkRefreshSettings: Equatable, Sendable {
    static let enabledKey = "STOCKBAR_BENCH_REFRESH"
    static let passesKey = "STOCKBAR_BENCH_REFRESH_PASSES"
    static let spacingKey = "STOCKBAR_BENCH_REFRESH_SPACING"

    let passes: Int
    let spacing: TimeInterval

    static let current = make(
        environment: ProcessInfo.processInfo.environment,
        runtime: StockbarRuntimeStorage.acceptance
    )

    static func make(environment: [String: String], runtime: StockbarAcceptanceRuntime) -> Self? {
        guard runtime.isEnabled, !runtime.liveProviderRequestsAllowed,
              environment[enabledKey] == "1",
              let passes = Int(environment[passesKey] ?? ""), (1...100).contains(passes),
              let spacing = TimeInterval(environment[spacingKey] ?? ""), (5...600).contains(spacing)
        else { return nil }
        return Self(passes: passes, spacing: spacing)
    }
}

/// Quotes for the benchmark's refresh passes. Until `arm()` it refuses every
/// request, as the Python service does in an acceptance run.
actor BenchmarkQuoteService: NetworkService {
    private let policy: StockbarProviderAccessPolicy
    private var isArmed = false
    private var batches = 0

    init(policy: StockbarProviderAccessPolicy = .current) {
        self.policy = policy
    }

    func arm() {
        isArmed = true
    }

    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult] {
        guard isArmed else { throw refusal() }
        batches += 1
        let time = Int(Date().timeIntervalSince1970)
        return symbols.map { Self.quote(for: $0, batch: batches, time: time) }
    }

    func fetchQuote(for symbol: String) async throws -> StockFetchResult {
        guard let quote = try await fetchBatchQuotes(for: [symbol]).first else {
            throw NetworkError.noData(symbol)
        }
        return quote
    }

    /// History is not part of the workload.
    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] {
        throw refusal()
    }

    func verifyAPIKey(service: String) async throws -> Bool {
        throw refusal()
    }

    /// The error the Python service gives in an acceptance run, logged the same way.
    private func refusal() -> Error {
        do {
            try policy.authorize(.python)
        } catch {
            return error
        }
        return ProviderAccessError.disabledForAcceptance(.python)
    }

    /// A price between 40 and 400, the same for a symbol in every run, moved
    /// a little by each batch so that every pass records new price rows.
    nonisolated static func quote(for symbol: String, batch: Int, time: Int) -> StockFetchResult {
        // FNV-1a: String.hashValue changes from one launch to the next.
        let seed = symbol.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        let previousClose = 40 + Double(seed % 36_000) / 100
        let price = previousClose * (1 + 0.001 * Double(batch % 10 + 1))
        return StockFetchResult(
            currency: "USD",
            symbol: symbol,
            shortName: "Synthetic \(symbol)",
            regularMarketTime: time,
            exchangeTimezoneName: "America/New_York",
            regularMarketPrice: price,
            regularMarketPreviousClose: previousClose,
            displayPrice: price,
            marketState: .regular
        )
    }
}

/// Runs the benchmark's refresh passes, the "Refresh now" kind, when the
/// benchmark sends SIGUSR1. Each pass starts `spacing` seconds after the one
/// before it.
@MainActor
final class BenchmarkRefreshDriver {
    private let settings: BenchmarkRefreshSettings
    private let quotes: BenchmarkQuoteService
    private let runPass: @MainActor () async -> Void
    private var signalSource: DispatchSourceSignal?
    private var hasStarted = false

    init(
        settings: BenchmarkRefreshSettings,
        quotes: BenchmarkQuoteService,
        runPass: @escaping @MainActor () async -> Void
    ) {
        self.settings = settings
        self.quotes = quotes
        self.runPass = runPass
    }

    func start() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.runPasses() }
        }
        source.resume()
        signalSource = source
        Task { await Logger.shared.info("Benchmark refresh: ready") }
    }

    private func runPasses() {
        guard !hasStarted else { return }
        hasStarted = true
        let settings = settings
        Task { @MainActor in
            await quotes.arm()
            await Logger.shared.info(
                "Benchmark refresh: starting \(settings.passes) passes \(Int(settings.spacing)) s apart"
            )
            let clock = ContinuousClock()
            let start = clock.now
            for pass in 1...settings.passes {
                await runPass()
                await Logger.shared.info("Benchmark refresh: pass \(pass) of \(settings.passes) finished")
                if pass < settings.passes {
                    try? await clock.sleep(until: start + .seconds(settings.spacing * Double(pass)))
                }
            }
        }
    }
}
