import Foundation

struct AICSource: ArtworkSourceProtocol {
    let source: ArtworkSource = .aic
    private let client: MuseumHTTPClient
    private static let fields = "id,title,artist_id,artist_title,date_display,date_start,date_end,updated_at,style_title,subject_titles,medium_display,dimensions,is_public_domain,image_id,thumbnail,credit_line"

    init(client: MuseumHTTPClient = .shared) { self.client = client }

    func search(query: String, page: Int = 1, pageSize: Int = 24) async throws -> [Artwork] {
        var components = URLComponents(string: "https://api.artic.edu/api/v1/artworks/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query.isEmpty ? "painting" : query),
            URLQueryItem(name: "query[term][is_public_domain]", value: "true"),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(max(1, min(pageSize, 100)))),
            URLQueryItem(name: "fields", value: Self.fields)
        ]
        let response = try JSONDecoder().decode(AICSearchResponse.self, from: await client.data(from: components.url!))
        return response.data.compactMap { try? normalizeMetadata($0) }.filter { licensePolicy(for: $0) }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let id = try MuseumMetadata.numericID(id, source: .aic)
        var components = URLComponents(string: "https://api.artic.edu/api/v1/artworks/\(id)")!
        components.queryItems = [URLQueryItem(name: "fields", value: Self.fields)]
        let response = try JSONDecoder().decode(AICDetailResponse.self, from: await client.data(from: components.url!))
        return try normalizeMetadata(response.data)
    }

    func fetchImageCandidates(for artwork: Artwork) async throws -> [URL] {
        guard licensePolicy(for: artwork) else { throw ArtworkSourceError.restrictedImage }
        return [artwork.image.originalURL]
    }

    func licensePolicy(for artwork: Artwork) -> Bool {
        artwork.source == .aic && artwork.isPublicDomain && artwork.image.license == "CC0 1.0"
            && artwork.image.originalURL.scheme == "https"
            && artwork.image.originalURL.host == "www.artic.edu"
            && artwork.image.originalURL.path.hasPrefix("/iiif/2/")
    }

    func normalizeMetadata(_ object: AICObject) throws -> Artwork {
        guard object.isPublicDomain == true else { throw ArtworkSourceError.restrictedImage }
        guard let imageID = object.imageID, !imageID.isEmpty,
              imageID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw ArtworkSourceError.unavailableImage }
        let base = "https://www.artic.edu/iiif/2/\(imageID)"
        return Artwork(
            id: "aic-\(object.id)", source: .aic, sourceID: String(object.id),
            titleOriginal: MuseumMetadata.text(object.title, fallback: "Untitled"),
            artistOriginal: MuseumMetadata.text(object.artistTitle, fallback: "Unknown artist"),
            dateDisplay: MuseumMetadata.text(object.dateDisplay, fallback: "Date unknown"),
            yearStart: object.dateStart, movement: MuseumMetadata.text(object.styleTitle, fallback: "Other"),
            themes: object.subjectTitles ?? [], medium: object.mediumDisplay, dimensions: object.dimensions,
            museumName: ArtworkSource.aic.displayName,
            sourceURL: URL(string: "https://www.artic.edu/artworks/\(object.id)")!,
            image: ArtworkImage(originalURL: URL(string: base + "/full/full/0/default.jpg")!,
                                thumbnailURL: URL(string: base + "/full/640,/0/default.jpg")!,
                                width: max(0, object.thumbnail?.width ?? 0),
                                height: max(0, object.thumbnail?.height ?? 0),
                                attribution: object.creditLine, license: "CC0 1.0",
                                detailURL: URL(string: base + "/full/2000,/0/default.jpg"),
                                availableSizes: object.thumbnail.flatMap { thumbnail in
                                    guard let width = thumbnail.width, let height = thumbnail.height, width > 0, height > 0 else { return nil }
                                    return [ArtworkImageSize(url: URL(string: base + "/full/full/0/default.jpg")!, width: width, height: height)]
                                }),
            isPublicDomain: true, artistID: object.artistID.map { "aic-artist-\($0)" },
            yearEnd: object.dateEnd, metadataUpdatedAt: object.updatedAt
        )
    }
}

struct AICSearchResponse: Decodable, Sendable { let data: [AICObject] }
struct AICDetailResponse: Decodable, Sendable { let data: AICObject }

struct AICObject: Decodable, Sendable {
    let id: Int
    let title: String?
    let artistTitle: String?
    let artistID: Int?
    let dateEnd: Int?
    let updatedAt: String?
    let dateDisplay: String?
    let dateStart: Int?
    let styleTitle: String?
    let subjectTitles: [String]?
    let mediumDisplay: String?
    let dimensions: String?
    let isPublicDomain: Bool?
    let imageID: String?
    let thumbnail: AICThumbnail?
    let creditLine: String?

    enum CodingKeys: String, CodingKey {
        case id, title, dimensions, thumbnail
        case artistID = "artist_id", dateEnd = "date_end", updatedAt = "updated_at"
        case artistTitle = "artist_title", dateDisplay = "date_display", dateStart = "date_start"
        case styleTitle = "style_title", subjectTitles = "subject_titles", mediumDisplay = "medium_display"
        case isPublicDomain = "is_public_domain", imageID = "image_id", creditLine = "credit_line"
    }
}

struct AICThumbnail: Decodable, Sendable { let width: Int?; let height: Int? }
