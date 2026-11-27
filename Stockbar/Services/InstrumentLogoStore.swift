import Foundation
import ImageIO
import UniformTypeIdentifiers

actor InstrumentLogoStore {
    static let enabledKey = "appearance.instrumentLogos"
    static let shared = InstrumentLogoStore()
    private static let maximumBytes = 256 * 1024

    private final class Entry {
        let image: CGImage?
        let expires: Date

        init(_ image: CGImage?) {
            self.image = image
            expires = Date().addingTimeInterval(image == nil ? 3_600 : 7 * 86_400)
        }
    }

    private let session: URLSession
    private let policy: StockbarProviderAccessPolicy
    private let cache = NSCache<NSURL, Entry>()
    private var pending: [URL: Task<CGImage?, Never>] = [:]

    init(session: URLSession? = nil, policy: StockbarProviderAccessPolicy = .current) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 3
        self.session = session ?? URLSession(configuration: configuration)
        self.policy = policy
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1024 * 1024
    }

    static func url(for symbol: String) -> URL? {
        let ticker = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ticker.utf8.count <= 32, PythonConfiguration.validateSymbol(ticker),
              ticker.first?.isLetter == true || ticker.first?.isNumber == true else { return nil }
        return URL(string: "https://images.financialmodelingprep.com/symbol/\(ticker).png")
    }

    func image(for symbol: String) async -> CGImage? {
        guard let url = Self.url(for: symbol), (try? policy.authorize(.instrumentLogos)) != nil else { return nil }
        if let entry = cache.object(forKey: url as NSURL), entry.expires > Date() { return entry.image }
        if let task = pending[url] { return await task.value }
        let task = Task { [session] in await Self.fetch(url, session: session) }
        pending[url] = task
        let result = await task.value
        let bytes = result.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(Entry(result), forKey: url as NSURL, cost: bytes)
        pending[url] = nil
        return result
    }

    private static func fetch(_ url: URL, session: URLSession) async -> CGImage? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType == "image/png", http.expectedContentLength <= maximumBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceThumbnailMaxPixelSize: 128,
                                           kCGImageSourceShouldCacheImmediately: true]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return trimmingTransparentMargins(of: thumbnail)
        } catch {
            return nil
        }
    }

    /// Crop only fully transparent margins. White artwork and antialiased edges count as ink.
    private static func trimmingTransparentMargins(of image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let width = image.width, height = image.height
        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format),
              let data = bitmap.data else { return image }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bitmap.draw(image, in: bounds)
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            let row = rgba.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<width where row[x * 4 + 3] != 0 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = y
            }
        }
        guard right >= left else { return nil }
        let ink = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return ink == bounds ? image : image.cropping(to: ink)
    }
}
