import Foundation

enum ArtworkSource: String, Codable, CaseIterable, Sendable {
    case met, aic, commons

    var displayName: String {
        switch self {
        case .met: "The Metropolitan Museum of Art"
        case .aic: "Art Institute of Chicago"
        case .commons: "Wikimedia Commons · Curated"
        }
    }
}

enum GuideStatus: String, Codable, Sendable {
    case missing, draft, published
}

/// Coordinates are normalized to the image, with an origin at its upper left.
struct NormalizedRect: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct NormalizedPoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct ArtworkImageSize: Codable, Hashable, Sendable {
    let url: URL
    let width: Int
    let height: Int
}

struct ArtworkImage: Codable, Hashable, Sendable {
    let originalURL: URL
    let thumbnailURL: URL
    /// Zero means the provider has not verified the source pixel dimensions.
    let width: Int
    let height: Int
    let attribution: String?
    let license: String
    let focalRegion: NormalizedRect?
    let detailURL: URL?
    /// Identifies the source image represented by an installed offline thumbnail.
    let bundledThumbnailSourceURL: URL?
    let availableSizes: [ArtworkImageSize]?
    let subjectBounds: NormalizedRect?
    let safeCropRect: NormalizedRect?
    let focalPoint: NormalizedPoint?

    init(originalURL: URL, thumbnailURL: URL, width: Int, height: Int,
         attribution: String? = nil, license: String, focalRegion: NormalizedRect? = nil,
         detailURL: URL? = nil, bundledThumbnailSourceURL: URL? = nil, availableSizes: [ArtworkImageSize]? = nil,
         subjectBounds: NormalizedRect? = nil, safeCropRect: NormalizedRect? = nil,
         focalPoint: NormalizedPoint? = nil) {
        self.originalURL = originalURL
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.height = height
        self.attribution = attribution
        self.license = license
        self.focalRegion = focalRegion
        self.detailURL = detailURL
        self.bundledThumbnailSourceURL = bundledThumbnailSourceURL
        self.availableSizes = availableSizes
        self.subjectBounds = subjectBounds
        self.safeCropRect = safeCropRect
        self.focalPoint = focalPoint
    }

    var hasVerifiedResolution: Bool { width > 0 && height > 0 }
}

struct ArtworkGuide: Codable, Hashable, Sendable {
    let summary30s: String
    let lookAtPoints: [String]
    let story: String?
    let visualAnalysis: String?
    let importance: String?
    let artistContext: String?
    let sourceRefs: [URL]
    let editorialVersion: Int

    init(summary30s: String, lookAtPoints: [String], story: String? = nil,
         visualAnalysis: String? = nil, importance: String? = nil, artistContext: String? = nil,
         sourceRefs: [URL], editorialVersion: Int = 1) {
        self.summary30s = summary30s
        self.lookAtPoints = lookAtPoints
        self.story = story
        self.visualAnalysis = visualAnalysis
        self.importance = importance
        self.artistContext = artistContext
        self.sourceRefs = sourceRefs
        self.editorialVersion = editorialVersion
    }
}

/// Immutable museum metadata. User state is persisted separately with SwiftData.
struct Artwork: Identifiable, Codable, Hashable, Sendable {
    /// Source-prefixed IDs are stable across launches and provider refreshes.
    let id: String
    let source: ArtworkSource
    let sourceID: String
    let titleOriginal: String
    let titleZh: String?
    let artistID: String?
    let artistOriginal: String
    let artistZh: String?
    let dateDisplay: String
    let yearStart: Int?
    let yearEnd: Int?
    let metadataUpdatedAt: String?
    let movement: String
    let movementZh: String?
    let themes: [String]
    let medium: String?
    let dimensions: String?
    let museumName: String
    let sourceURL: URL
    let image: ArtworkImage
    let isPublicDomain: Bool
    let metadataLicense: String
    let guideStatus: GuideStatus
    let dominantColors: [String]
    let guide: ArtworkGuide?

    init(id: String, source: ArtworkSource, sourceID: String, titleOriginal: String,
         titleZh: String? = nil, artistOriginal: String, artistZh: String? = nil,
         dateDisplay: String, yearStart: Int? = nil, movement: String = "Other",
         movementZh: String? = nil, themes: [String] = [], medium: String? = nil,
         dimensions: String? = nil, museumName: String, sourceURL: URL, image: ArtworkImage,
         isPublicDomain: Bool, metadataLicense: String = "CC0 1.0",
         guideStatus: GuideStatus = .missing, dominantColors: [String] = [], guide: ArtworkGuide? = nil,
         artistID: String? = nil, yearEnd: Int? = nil, metadataUpdatedAt: String? = nil) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.titleOriginal = titleOriginal
        self.titleZh = titleZh
        self.artistID = artistID
        self.artistOriginal = artistOriginal
        self.artistZh = artistZh
        self.dateDisplay = dateDisplay
        self.yearStart = yearStart
        self.yearEnd = yearEnd
        self.metadataUpdatedAt = metadataUpdatedAt
        self.movement = movement
        self.movementZh = movementZh
        self.themes = themes
        self.medium = medium
        self.dimensions = dimensions
        self.museumName = museumName
        self.sourceURL = sourceURL
        self.image = image
        self.isPublicDomain = isPublicDomain
        self.metadataLicense = metadataLicense
        self.guideStatus = guideStatus
        self.dominantColors = dominantColors
        self.guide = guide
    }

    var displayTitle: String { titleZh?.nonempty ?? titleOriginal }
    var displayArtist: String { artistZh?.nonempty ?? artistOriginal }
    var aspectRatio: Double {
        image.hasVerifiedResolution ? Double(image.width) / Double(image.height) : 4.0 / 3.0
    }
    var orientation: String {
        guard image.hasVerifiedResolution else { return "unknown" }
        return aspectRatio > 1.12 ? "landscape" : aspectRatio < 0.9 ? "portrait" : "square"
    }
    var hasPublishedGuide: Bool { guideStatus == .published && guide != nil }
    var searchText: String {
        ([titleOriginal, titleZh ?? "", artistOriginal, artistZh ?? "", movement, movementZh ?? ""] + themes)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
