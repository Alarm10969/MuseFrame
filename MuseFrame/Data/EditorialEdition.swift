import CryptoKit
import Foundation

/// One static JSON document publishes catalog order and its matching guide and graph revisions.
struct EditorialEdition: Sendable {
    let revision: Int
    let artworks: [Artwork]
    let history: Data
    let guides: Data

    init(data: Data) throws {
        guard data.count <= 16 * 1024 * 1024,
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["schemaVersion"] as? Int == 1, let revision = document["revision"] as? Int, revision > 0,
              let rows = document["artworks"] as? [[String: Any]], !rows.isEmpty,
              let history = document["history"] as? [String: Any], let guides = document["guides"] as? [String: Any],
              ["artists","movements","artistRelationships","artworkRelationships","artworkAnnotations","timelineEvents"]
                .allSatisfy({ history[$0] is [Any] }), guides["guides"] is [Any] else { throw ArtworkSourceError.invalidCatalog }
        self.revision = revision
        artworks = try JSONDecoder().decode([Artwork].self, from: JSONSerialization.data(withJSONObject: rows))
        guard Set(artworks.map(\.id)).count == artworks.count,
              artworks.allSatisfy(Self.isPermitted) else { throw ArtworkSourceError.restrictedImage }
        self.history = try JSONSerialization.data(withJSONObject: history)
        self.guides = try JSONSerialization.data(withJSONObject: guides)
        let snapshot = ArtHistoryRepository.decode(historyData: self.history, guideData: self.guides, artworks: artworks)
        guard snapshot.diagnostics.isEmpty else { throw ArtworkSourceError.invalidCatalog }
    }

    private static func isPermitted(_ artwork: Artwork) -> Bool {
        let provider: any ArtworkSourceProtocol
        switch artwork.source {
        case .met: provider = MetMuseumSource()
        case .commons: provider = CuratedCommonsSource()
        case .aic: return false
        }
        guard artwork.id == artwork.source.rawValue + "-" + artwork.sourceID,
              provider.licensePolicy(for: artwork), artwork.sourceURL.scheme == "https" else { return false }
        let image = artwork.image
        var urls = [image.originalURL, image.thumbnailURL]
        if let detail = image.detailURL { urls.append(detail) }
        urls.append(contentsOf: (image.availableSizes ?? []).map(\.url))
        return urls.allSatisfy { url in
            url.scheme == "https" && url.host == image.originalURL.host && url.user == nil && url.password == nil
        }
    }
}

actor EditorialStore {
    private let directory: URL
    private let session: URLSession

    init(directory: URL? = nil, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("MuseFrame/Editorial")
        self.session = session
    }

    static func accepts(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost","127.0.0.1","::1"].contains(url.host))
    }

    private func file(for address: URL) -> URL {
        let key = SHA256.hash(data: Data(address.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    func cached(at address: URL) -> EditorialEdition? {
        guard Self.accepts(address), let bytes = try? Data(contentsOf: file(for: address)) else { return nil }
        return try? EditorialEdition(data: bytes)
    }

    func refresh(at address: URL) async throws -> EditorialEdition {
        guard Self.accepts(address) else { throw ArtworkSourceError.invalidCatalog }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (temp, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, Self.accepts(final), final.scheme == address.scheme,
              let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else {
            throw ArtworkSourceError.invalidResponse
        }
        let bytes = try Data(contentsOf: temp)
        let edition = try EditorialEdition(data: bytes)
        try Task.checkCancellation()
        if let previous = cached(at: address), previous.revision >= edition.revision { return previous }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file(for: address), options: .atomic)
        return edition
    }
}
