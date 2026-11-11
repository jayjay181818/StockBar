import Foundation

enum StockbarProvider: String, CaseIterable, Sendable {
    /// Covers the whole Python bridge. yfinance, FMP and Twelve Data all
    /// run *inside* `get_stock_data.py`, so they are gated transitively by this
    /// case rather than having cases of their own.
    case python
    case directFX
    case trading212
    case folync
}

enum ProviderAccessError: Error, Equatable, LocalizedError {
    case disabledForAcceptance(StockbarProvider)

    var errorDescription: String? {
        switch self {
        case .disabledForAcceptance(let provider):
            return "Live provider \(provider.rawValue) is disabled for this Stockbar acceptance run."
        }
    }
}

struct StockbarProviderAccessPolicy: Sendable {
    static let current = StockbarProviderAccessPolicy(runtime: StockbarRuntimeStorage.acceptance)

    let liveRequestsAllowed: Bool

    init(liveRequestsAllowed: Bool) {
        self.liveRequestsAllowed = liveRequestsAllowed
    }

    init(runtime: StockbarAcceptanceRuntime) {
        self.liveRequestsAllowed = runtime.liveProviderRequestsAllowed
    }

    func authorize(_ provider: StockbarProvider) throws {
        guard liveRequestsAllowed else {
            Task {
                await Logger.shared.warning("provider_access_denied provider=\(provider.rawValue) mode=acceptance")
            }
            throw ProviderAccessError.disabledForAcceptance(provider)
        }
    }
}
