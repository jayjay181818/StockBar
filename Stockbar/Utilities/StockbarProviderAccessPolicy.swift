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
    /// Whether `authorize(.folync, endpoint:)` lets a request to this Mac
    /// through while live requests are off. See that method.
    let loopbackFolyncAllowed: Bool

    init(liveRequestsAllowed: Bool) {
        self.liveRequestsAllowed = liveRequestsAllowed
        self.loopbackFolyncAllowed = false
    }

    init(runtime: StockbarAcceptanceRuntime) {
        self.liveRequestsAllowed = runtime.liveProviderRequestsAllowed
        self.loopbackFolyncAllowed = runtime.loopbackFolyncAllowed
    }

    func authorize(_ provider: StockbarProvider) throws {
        guard liveRequestsAllowed else { throw denied(provider) }
    }

    /// Like `authorize(_:)`, with one exception for an acceptance run: a Folync
    /// request whose endpoint is on this Mac is let through.
    ///
    /// The acceptance harness requires its Folync to be a stand-in on loopback
    /// that serves made-up data, so reaching it is not a live provider
    /// request. The exception goes by endpoint and is checked on every
    /// request, not once at startup, so changing the Folync address inside
    /// the acceptance copy to another machine is still refused. No other
    /// provider, and no other kind of run, gets it.
    func authorize(_ provider: StockbarProvider, endpoint: URL) throws {
        if liveRequestsAllowed { return }
        if provider == .folync, loopbackFolyncAllowed, Self.isLoopback(endpoint) { return }
        throw denied(provider)
    }

    /// True for an `http` or `https` URL whose host is exactly `127.0.0.1`,
    /// `localhost` or `::1` (Foundation reports `http://[::1]:4100` as `::1`).
    /// Compares the whole host, with no prefix or suffix matching and no name
    /// lookup, so `127.0.0.1.example.com` and `http://127.0.0.1@host/` are not
    /// loopback.
    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func denied(_ provider: StockbarProvider) -> ProviderAccessError {
        Task {
            await Logger.shared.warning("provider_access_denied provider=\(provider.rawValue) mode=acceptance")
        }
        return ProviderAccessError.disabledForAcceptance(provider)
    }
}
