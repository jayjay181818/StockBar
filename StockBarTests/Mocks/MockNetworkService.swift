import Foundation
@testable import StockBar

class MockNetworkService: NetworkService {
    var mockResults: [Result] = []
    var error: Error?

    func fetchQuote(for symbol: String) async throws -> Result {
        if let error = error {
            throw error
        }
        return mockResults[0]
    }

    func fetchBatchQuotes(for symbols: [String]) async throws -> [Result] {
        if let error = error {
            throw error
        }
        return mockResults
    }
}

// Mock Error for testing
enum MockError: Error {
    case networkError
    case invalidData
}
