@testable import StockBar
import XCTest

class NetworkServiceTests: XCTestCase {
    var sut: YahooFinanceService!
    var mockSession: MockURLSession!

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        sut = YahooFinanceService(session: mockSession)
    }

    override func tearDown() {
        sut = nil
        mockSession = nil
        super.tearDown()
    }

    func testFetchQuoteSuccess() async throws {
        // Given
        let mockData = """
        {
            "quoteResponse": {
                "result": [{
                    "symbol": "AAPL",
                    "shortName": "Apple Inc.",
                    "regularMarketTime": 1634924400,
                    "exchangeTimezoneName": "America/New_York",
                    "regularMarketPrice": 149.80,
                    "regularMarketPreviousClose": 148.69,
                    "currency": "USD"
                }]
            }
        }
        """.data(using: .utf8)!

        mockSession.mockData = mockData
        mockSession.mockResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)

        // When
        let result = try await sut.fetchQuote(for: "AAPL")

        // Then
        XCTAssertEqual(result.symbol, "AAPL")
        XCTAssertEqual(result.regularMarketPrice, 149.80)
    }

    func testFetchQuoteHTTPError() async {
        // Given
        mockSession.mockResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil)

        // When/Then
        do {
            _ = try await sut.fetchQuote(for: "INVALID")
            XCTFail("Expected error but got success")
        } catch NetworkError.httpError(let code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testFetchBatchQuotesSuccess() async throws {
        // Given
        let mockData = """
        {
            "quoteResponse": {
                "result": [
                    {
                        "symbol": "AAPL",
                        "shortName": "Apple Inc.",
                        "regularMarketTime": 1634924400,
                        "exchangeTimezoneName": "America/New_York",
                        "regularMarketPrice": 149.80,
                        "regularMarketPreviousClose": 148.69,
                        "currency": "USD"
                    },
                    {
                        "symbol": "MSFT",
                        "shortName": "Microsoft Corporation",
                        "regularMarketTime": 1634924400,
                        "exchangeTimezoneName": "America/New_York",
                        "regularMarketPrice": 309.16,
                        "regularMarketPreviousClose": 307.29,
                        "currency": "USD"
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        mockSession.mockData = mockData
        mockSession.mockResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)

        // When
        let results = try await sut.fetchBatchQuotes(for: ["AAPL", "MSFT"])

        // Then
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].symbol, "AAPL")
        XCTAssertEqual(results[1].symbol, "MSFT")
    }
}

// Mock URLSession for testing
class MockURLSession: URLSession {
    var mockData: Data?
    var mockResponse: URLResponse?
    var mockError: Error?

    override func data(
        from url: URL,
        delegate: URLSessionTaskDelegate? = nil
    ) async throws -> (Data, URLResponse) {
        if let error = mockError {
            throw error
        }
        return (
            mockData ?? Data(),
            mockResponse ?? URLResponse()
        )
    }
}
