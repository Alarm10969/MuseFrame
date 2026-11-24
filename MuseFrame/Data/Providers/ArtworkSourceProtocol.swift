import Foundation

protocol ArtworkSourceProtocol: Sendable {
    var source: ArtworkSource { get }
    func search(query: String, page: Int, pageSize: Int) async throws -> [Artwork]
    func fetchArtwork(id: String) async throws -> Artwork
    func fetchImageCandidates(for artwork: Artwork) async throws -> [URL]
    func licensePolicy(for artwork: Artwork) -> Bool
    func updatedArtworkIDs(since: Date, offset: Int, limit: Int) async throws -> ArtworkIDPage?
}

struct ArtworkIDPage: Sendable {
    let ids: [String]
    let hasMore: Bool
}

extension ArtworkSourceProtocol {
    /// Sources without a changes feed still receive bounded metadata revalidation.
    func updatedArtworkIDs(since: Date, offset: Int, limit: Int) async throws -> ArtworkIDPage? { nil }
}

enum ArtworkSourceError: Error, LocalizedError, Sendable {
    case invalidID
    case invalidResponse
    case unavailableImage
    case restrictedImage
    case httpStatus(Int)
    case missingSeed
    case invalidCatalog

    var errorDescription: String? {
        switch self {
        case .invalidID: "作品编号无效。"
        case .invalidResponse: "博物馆返回的数据暂时无法读取。"
        case .unavailableImage: "这件作品暂时没有可用图片。"
        case .restrictedImage: "这件作品的图片未明确开放使用。"
        case .httpStatus(let status): "博物馆服务暂时不可用（\(status)）。"
        case .missingSeed: "找不到内置画作数据。"
        case .invalidCatalog: "本地画作资料库需要更新。"
        }
    }
}

/// One shared client keeps retries bounded and respects the AIC's one-request/second guidance.
actor MuseumHTTPClient {
    static let shared = MuseumHTTPClient()
    private var lastAICRequest: Date?
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func data(from url: URL) async throws -> Data {
        for attempt in 0...2 {
            try Task.checkCancellation()
            if url.host == "api.artic.edu" {
                // Reserve the next slot before suspending so reentrant calls cannot share it.
                let slot = max(Date(), (lastAICRequest ?? .distantPast).addingTimeInterval(1.05))
                lastAICRequest = slot
                let delay = slot.timeIntervalSinceNow
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("MuseFrame/0.1 (native macOS open-access gallery)", forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where attempt < 2 && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
                try await Task.sleep(for: .seconds(Double(attempt + 1)))
                continue
            }
            guard let response = response as? HTTPURLResponse else { throw ArtworkSourceError.invalidResponse }
            if (200..<300).contains(response.statusCode) { return data }
            if (response.statusCode == 429 || response.statusCode >= 500), attempt < 2 {
                let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "")
                try await Task.sleep(for: .seconds(min(retryAfter ?? Double(attempt + 1), 10)))
                continue
            }
            throw ArtworkSourceError.httpStatus(response.statusCode)
        }
        throw ArtworkSourceError.invalidResponse
    }
}

enum MuseumMetadata {
    static func numericID(_ id: String, source: ArtworkSource) throws -> String {
        let value = id.hasPrefix(source.rawValue + "-") ? String(id.dropFirst(source.rawValue.count + 1)) : id
        guard !value.isEmpty, value.allSatisfy(\.isNumber), Int(value) != nil else { throw ArtworkSourceError.invalidID }
        return value
    }

    static func httpsURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func text(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
