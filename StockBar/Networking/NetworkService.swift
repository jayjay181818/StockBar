import Foundation

/// Protocol defining network service capabilities for stock data fetching
protocol NetworkService {
    /// Fetches quote data for a single stock symbol
    /// - Parameter symbol: The stock symbol to fetch
    /// - Returns: Result containing stock data
    /// - Throws: Network or parsing errors
    func fetchQuote(for symbol: String) async throws -> Result

    /// Fetches quote data for multiple stock symbols in a single request
    /// - Parameter symbols: Array of stock symbols to fetch
    /// - Returns: Array of Results containing stock data
    /// - Throws: Network or parsing errors
    func fetchBatchQuotes(for symbols: [String]) async throws -> [Result]
}

/// Implementation of NetworkService using Yahoo Finance API
class YahooFinanceService: NetworkService {
    private let session: URLSession
    private let baseURL = "https://query1.finance.yahoo.com/v6/finance/quote"

    init(session: URLSession = .shared) {
        self.session = session
        Logger.shared.log(.debug, "Initialized YahooFinanceService")
    }

    func fetchQuote(for symbol: String) async throws -> Result {
        Logger.shared.log(.info, "Fetching quote for symbol: \(symbol)")
        return try await fetchBatchQuotes(for: [symbol]).first ??
            Result(currency: nil,
                  symbol: symbol,
                  shortName: "",
                  regularMarketTime: 0,
                  exchangeTimezoneName: "",
                  regularMarketPrice: 0.0,
                  regularMarketPreviousClose: 0.0)
    }

    func fetchBatchQuotes(for symbols: [String]) async throws -> [Result] {
        Logger.shared.log(.info, "Fetching batch quotes for symbols: \(symbols.joined(separator: ", "))")

        guard let url = makeURL(for: symbols) else {
            Logger.shared.log(.error, "Failed to create URL for symbols: \(symbols)")
            throw NetworkError.invalidURL
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.shared.log(.error, "Invalid response type")
                throw NetworkError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                Logger.shared.log(.error, "HTTP error: \(httpResponse.statusCode)")
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            let quote = try JSONDecoder().decode(YahooFinanceQuote.self, from: data)

            guard let results = quote.quoteResponse?.result,
                  !results.isEmpty else {
                Logger.shared.log(.error, "No data in response")
                throw NetworkError.noData
            }

            Logger.shared.log(.debug, "Successfully fetched \(results.count) quotes")
            return results
        } catch {
            Logger.shared.log(.error, "Network request failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func makeURL(for symbols: [String]) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))
        ]
        return components?.url
    }
}

/// Errors that can occur during network operations
enum NetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .noData:
            return "No data received"
        }
    }
}
