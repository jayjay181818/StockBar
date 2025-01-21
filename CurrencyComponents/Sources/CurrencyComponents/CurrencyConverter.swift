import Combine
import Foundation

public final class CurrencyConverter: NSObject, ObservableObject {
    @available(*, deprecated, message: "Use shared instance through dependency injection")
    public static let shared = CurrencyConverter()

    @Published public var exchangeRates: [String: Double] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let baseCurrency = "USD"
    private let currencyPairs = ["GBPUSD=X", "EURUSD=X", "JPYUSD=X", "CADUSD=X", "AUDUSD=X"]

    private init() {
        refreshRates()
        // Auto-refresh every hour
        Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshRates()
            }
            .store(in: &cancellables)
    }

    func refreshRates() {
        let symbols = currencyPairs.joined(separator: ",")
        guard let url = URL(string: "https://query1.finance.yahoo.com/v6/finance/quote?symbols=\(symbols)") else { return }

        URLSession.shared.dataTaskPublisher(for: url)
            .map(\.data)
            .decode(type: YahooFinanceResponse.self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("Currency fetch error: \(error)")
                    }
                },
                receiveValue: { [weak self] response in
                    self?.processResponse(response)
                }
            )
            .store(in: &cancellables)
    }

    private func processResponse(_ response: YahooFinanceResponse) {
        var newRates = [String: Double]()
        for quote in response.quoteResponse.result {
            let currencyPair = quote.symbol.replacingOccurrences(of: "=X", with: "")
            let rate = 1 / quote.regularMarketPrice
            newRates[currencyPair] = rate
        }
        exchangeRates = newRates
    }

    func convert(amount: Double, from: String, to: String) -> Double {
        let fromRate = exchangeRates[from] ?? 1.0
        let toRate = exchangeRates[to] ?? 1.0
        return amount * (toRate / fromRate)
    }
}

private struct YahooFinanceResponse: Decodable {
    let quoteResponse: QuoteResponse

    struct QuoteResponse: Decodable {
        let result: [Quote]
    }

    struct Quote: Decodable {
        let symbol: String
        let regularMarketPrice: Double
    }
}
