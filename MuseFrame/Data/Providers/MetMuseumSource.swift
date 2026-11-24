import Foundation

struct MetMuseumSource: ArtworkSourceProtocol {
    let source: ArtworkSource = .met
    private let client: MuseumHTTPClient

    init(client: MuseumHTTPClient = .shared) { self.client = client }

    func search(query: String, page: Int = 1, pageSize: Int = 24) async throws -> [Artwork] {
        let size = max(1, min(pageSize, 80))
        var components = URLComponents(string: "https://collectionapi.metmuseum.org/public/collection/v1.1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query.isEmpty ? "painting" : query),
            URLQueryItem(name: "hasImages", value: "true"),
            URLQueryItem(name: "departmentId", value: "11"),
            URLQueryItem(name: "offset", value: String(max(0, page - 1) * size)),
            URLQueryItem(name: "limit", value: String(size))
        ]
        let response = try JSONDecoder().decode(MetSearchResponse.self, from: await client.data(from: components.url!))
        var result: [Artwork] = []
        // Limit detail traffic and preserve the museum's result order.
        for id in response.objectIDs ?? [] {
            try Task.checkCancellation()
            do {
                let artwork = try await fetchArtwork(id: String(id))
                if licensePolicy(for: artwork) { result.append(artwork) }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch ArtworkSourceError.restrictedImage {
                continue
            } catch ArtworkSourceError.unavailableImage {
                continue
            }
        }
        return result
    }

    func updatedArtworkIDs(since: Date, offset: Int, limit: Int) async throws -> ArtworkIDPage? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var components = URLComponents(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects")!
        components.queryItems = [URLQueryItem(name: "metadataDate", value: formatter.string(from: since)),
                                 URLQueryItem(name: "departmentIds", value: "1|11")]
        let response = try JSONDecoder().decode(MetSearchResponse.self, from: await client.data(from: components.url!))
        // Sort IDs because the API does not promise an order across repeat calls.
        let ids = (response.objectIDs ?? []).sorted()
        let start = max(0, min(offset, ids.count))
        let end = min(ids.count, start + max(1, min(limit, 24)))
        return ArtworkIDPage(ids: ids[start..<end].map { "met-\($0)" }, hasMore: end < ids.count)
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let id = try MuseumMetadata.numericID(id, source: .met)
        let url = URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects/\(id)")!
        let object = try JSONDecoder().decode(MetObject.self, from: await client.data(from: url))
        return try normalizeMetadata(object)
    }

    func fetchImageCandidates(for artwork: Artwork) async throws -> [URL] {
        guard licensePolicy(for: artwork) else { throw ArtworkSourceError.restrictedImage }
        return [artwork.image.originalURL]
    }

    func licensePolicy(for artwork: Artwork) -> Bool {
        artwork.source == .met && artwork.isPublicDomain && artwork.image.license == "CC0 1.0"
            && artwork.image.originalURL.scheme == "https"
            && artwork.image.originalURL.host == "images.metmuseum.org"
    }

    func normalizeMetadata(_ object: MetObject) throws -> Artwork {
        guard object.isPublicDomain == true else { throw ArtworkSourceError.restrictedImage }
        guard let original = MuseumMetadata.httpsURL(object.primaryImage) else { throw ArtworkSourceError.unavailableImage }
        // Gallery must never silently fall back to a full-size download.
        guard let thumbnail = MuseumMetadata.httpsURL(object.primaryImageSmall) else {
            throw ArtworkSourceError.unavailableImage
        }
        let sourceURL = MuseumMetadata.httpsURL(object.objectURL)
            ?? URL(string: "https://www.metmuseum.org/art/collection/search/\(object.objectID)")!
        return Artwork(
            id: "met-\(object.objectID)", source: .met, sourceID: String(object.objectID),
            titleOriginal: MuseumMetadata.text(object.title, fallback: "Untitled"),
            artistOriginal: MuseumMetadata.text(object.artistDisplayName, fallback: "Unknown artist"),
            dateDisplay: MuseumMetadata.text(object.objectDate, fallback: "Date unknown"),
            yearStart: object.objectBeginDate, movement: MuseumMetadata.text(object.period, fallback: "Other"),
            themes: object.tags?.compactMap(\.term) ?? [], medium: object.medium, dimensions: object.dimensions,
            museumName: ArtworkSource.met.displayName, sourceURL: sourceURL,
            // The Met object API supplies no pixel dimensions. Unknown dimensions never qualify as HD.
            image: ArtworkImage(originalURL: original, thumbnailURL: thumbnail, width: 0, height: 0,
                                attribution: object.creditLine, license: "CC0 1.0"),
            isPublicDomain: true,
            artistID: object.constituents?.first(where: { $0.role == "Artist" }).map { "met-artist-\($0.constituentID)" },
            yearEnd: object.objectEndDate, metadataUpdatedAt: object.metadataDate
        )
    }
}

struct MetSearchResponse: Decodable, Sendable { let total: Int; let objectIDs: [Int]? }

struct MetObject: Decodable, Sendable {
    let objectID: Int
    let isPublicDomain: Bool?
    let primaryImage: String?
    let primaryImageSmall: String?
    let title: String?
    let artistDisplayName: String?
    let objectDate: String?
    let objectBeginDate: Int?
    let objectEndDate: Int?
    let metadataDate: String?
    let constituents: [MetConstituent]?
    let period: String?
    let medium: String?
    let dimensions: String?
    let objectURL: String?
    let creditLine: String?
    let tags: [MetTag]?
}

struct MetTag: Decodable, Sendable { let term: String? }

struct MetConstituent: Decodable, Sendable {
    let constituentID: Int
    let role: String?
}
