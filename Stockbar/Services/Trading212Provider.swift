import Foundation

enum Trading212ProviderError: Error, LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Trading 212 returned an invalid response."
        case .unauthorized:
            return "Trading 212 rejected the credentials. Check the API key, API secret, and live/demo environment."
        case .forbidden:
            return "Trading 212 permission is missing for this request."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Trading 212 rate limit reached. Retry in \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "Trading 212 rate limit reached. Wait before testing again."
        case .httpStatus(let status):
            return "Trading 212 request failed with HTTP \(status)."
        case .decodingFailed:
            return "Trading 212 returned data StockBar could not read."
        }
    }
}

struct Trading212Provider {
    private let session: URLSession
    private let authHeaderBuilder: Trading212AuthHeaderBuilder
    private let decoder: JSONDecoder
    private let providerPolicy: StockbarProviderAccessPolicy

    init(
        session: URLSession = .shared,
        authHeaderBuilder: Trading212AuthHeaderBuilder = Trading212AuthHeaderBuilder(),
        providerPolicy: StockbarProviderAccessPolicy = .current
    ) {
        self.session = session
        self.authHeaderBuilder = authHeaderBuilder
        self.decoder = JSONDecoder()
        self.providerPolicy = providerPolicy
    }

    func accountSummary(
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async throws -> Trading212AccountSummary {
        try await get("/equity/account/summary", credentials: credentials, environment: environment)
    }

    func positions(
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async throws -> [Trading212Position] {
        try await get("/equity/positions", credentials: credentials, environment: environment)
    }

    func instruments(
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async throws -> [Trading212InstrumentMetadata] {
        try await get("/equity/metadata/instruments", credentials: credentials, environment: environment)
    }

    func exchanges(
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async throws -> [Trading212ExchangeMetadata] {
        try await get("/equity/metadata/exchanges", credentials: credentials, environment: environment)
    }

    func metadataAvailable(
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async -> Bool {
        do {
            _ = try await instruments(credentials: credentials, environment: environment)
            return true
        } catch {
            return false
        }
    }

    private func get<T: Decodable>(
        _ path: String,
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async throws -> T {
        try providerPolicy.authorize(.trading212)
        let request = try makeRequest(path: path, credentials: credentials, environment: environment)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Trading212ProviderError.invalidResponse
        }
        try validate(httpResponse)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw Trading212ProviderError.decodingFailed(error.localizedDescription)
        }
    }

    private func makeRequest(
        path: String,
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) throws -> URLRequest {
        let baseURL = environment.baseURL
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let header = try authHeaderBuilder.authorizationHeader(for: credentials)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(header.value, forHTTPHeaderField: header.name)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw Trading212ProviderError.unauthorized
        case 403:
            throw Trading212ProviderError.forbidden
        case 429:
            throw Trading212ProviderError.rateLimited(retryAfter: retryAfter(from: response))
        default:
            throw Trading212ProviderError.httpStatus(response.statusCode)
        }
    }

    private func retryAfter(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

struct Trading212BackoffPolicy: Sendable {
    private static let steps: [TimeInterval] = [60, 120, 300, 900, 1_800, 3_600]

    let configuredInterval: TimeInterval
    let jitterFraction: Double

    init(configuredInterval: TimeInterval, jitterFraction: Double = 0.10) {
        self.configuredInterval = max(60, configuredInterval)
        self.jitterFraction = max(0, min(0.10, jitterFraction))
    }

    func delay(
        failureCount: Int,
        retryAfter: TimeInterval? = nil,
        randomUnit: Double = Double.random(in: -1...1)
    ) -> TimeInterval {
        let index = min(max(0, failureCount - 1), Self.steps.count - 1)
        let base = max(configuredInterval, retryAfter ?? 0, Self.steps[index])
        return base * (1 + (max(-1, min(1, randomUnit)) * jitterFraction))
    }
}
