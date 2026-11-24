import Foundation

/// Versioned editorial metadata, independent of museum records and SwiftData user state.
struct Artist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let nameOriginal: String
    let nameZh: String?
    let birthYear: Int?
    let deathYear: Int?
    let region: String?
    let movementIDs: [String]
    let shortBioZh: String?
    let sourceRefs: [URL]
    let representativeArtworkIDs: [String]
    let portraitArtworkID: String?
    let aliases: [String]
    let importanceRank: Int

    init(id: String, nameOriginal: String, nameZh: String? = nil, birthYear: Int? = nil,
         deathYear: Int? = nil, region: String? = nil, movementIDs: [String] = [],
         shortBioZh: String? = nil, sourceRefs: [URL], representativeArtworkIDs: [String] = [],
         portraitArtworkID: String? = nil, aliases: [String] = [], importanceRank: Int = 1) {
        self.id = id; self.nameOriginal = nameOriginal; self.nameZh = nameZh
        self.birthYear = birthYear; self.deathYear = deathYear; self.region = region
        self.movementIDs = movementIDs; self.shortBioZh = shortBioZh; self.sourceRefs = sourceRefs
        self.representativeArtworkIDs = representativeArtworkIDs; self.portraitArtworkID = portraitArtworkID
        self.aliases = aliases; self.importanceRank = importanceRank
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), nameOriginal: try c.decode(String.self, forKey: .nameOriginal),
            nameZh: try c.decodeIfPresent(String.self, forKey: .nameZh),
            birthYear: try c.decodeIfPresent(Int.self, forKey: .birthYear), deathYear: try c.decodeIfPresent(Int.self, forKey: .deathYear),
            region: try c.decodeIfPresent(String.self, forKey: .region), movementIDs: try c.decodeIfPresent([String].self, forKey: .movementIDs) ?? [],
            shortBioZh: try c.decodeIfPresent(String.self, forKey: .shortBioZh), sourceRefs: try c.decode([URL].self, forKey: .sourceRefs),
            representativeArtworkIDs: try c.decodeIfPresent([String].self, forKey: .representativeArtworkIDs) ?? [],
            portraitArtworkID: try c.decodeIfPresent(String.self, forKey: .portraitArtworkID),
            aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [], importanceRank: try c.decodeIfPresent(Int.self, forKey: .importanceRank) ?? 1)
    }

    var displayName: String { nameZh?.historyNonempty ?? nameOriginal }
    var yearsDisplay: String {
        switch (birthYear, deathYear) {
        case (.some(let birth), nil): return "生于 \(birth)"
        case (nil, .some(let death)): return "卒于 \(death)"
        default: return HistoryText.years(birthYear, deathYear)
        }
    }
    var activityMidYear: Double {
        if let birthYear, let deathYear { return Double(birthYear) / 2 + Double(deathYear) / 2 }
        return Double(birthYear ?? deathYear ?? 1800)
    }
    var searchText: String { ([nameOriginal, nameZh ?? ""] + aliases).joined(separator: " ") }
}

struct Movement: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let nameOriginal: String
    let nameZh: String?
    let startYear: Int?
    let endYear: Int?
    let summaryZh: String?
    let sourceRefs: [URL]
    let displayColorToken: String
    let sortOrder: Int
    let keyArtistIDs: [String]
    let keyArtworkIDs: [String]
    let previousMovementIDs: [String]
    let nextMovementIDs: [String]

    init(id: String, nameOriginal: String, nameZh: String? = nil, startYear: Int? = nil, endYear: Int? = nil,
         summaryZh: String? = nil, sourceRefs: [URL], displayColorToken: String = "gray", sortOrder: Int = 0,
         keyArtistIDs: [String] = [], keyArtworkIDs: [String] = [], previousMovementIDs: [String] = [], nextMovementIDs: [String] = []) {
        self.id = id; self.nameOriginal = nameOriginal; self.nameZh = nameZh
        self.startYear = startYear; self.endYear = endYear; self.summaryZh = summaryZh; self.sourceRefs = sourceRefs
        self.displayColorToken = displayColorToken; self.sortOrder = sortOrder
        self.keyArtistIDs = keyArtistIDs; self.keyArtworkIDs = keyArtworkIDs
        self.previousMovementIDs = previousMovementIDs; self.nextMovementIDs = nextMovementIDs
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), nameOriginal: try c.decode(String.self, forKey: .nameOriginal),
            nameZh: try c.decodeIfPresent(String.self, forKey: .nameZh), startYear: try c.decodeIfPresent(Int.self, forKey: .startYear),
            endYear: try c.decodeIfPresent(Int.self, forKey: .endYear), summaryZh: try c.decodeIfPresent(String.self, forKey: .summaryZh),
            sourceRefs: try c.decode([URL].self, forKey: .sourceRefs), displayColorToken: try c.decodeIfPresent(String.self, forKey: .displayColorToken) ?? "gray",
            sortOrder: try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
            keyArtistIDs: try c.decodeIfPresent([String].self, forKey: .keyArtistIDs) ?? [],
            keyArtworkIDs: try c.decodeIfPresent([String].self, forKey: .keyArtworkIDs) ?? [],
            previousMovementIDs: try c.decodeIfPresent([String].self, forKey: .previousMovementIDs) ?? [],
            nextMovementIDs: try c.decodeIfPresent([String].self, forKey: .nextMovementIDs) ?? [])
    }

    var displayName: String { nameZh?.historyNonempty ?? nameOriginal }
    var yearsDisplay: String { HistoryText.years(startYear, endYear) }
}

struct ArtistRelationship: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case influence, crossedPaths, parallelPaths, teacherStudent
        var isDirected: Bool { self == .influence || self == .teacherStudent }
        var displayName: String {
            switch self {
            case .influence: "影响"
            case .crossedPaths: "相遇"
            case .parallelPaths: "并行探索"
            case .teacherStudent: "师生"
            }
        }
    }
    let id: String
    let fromArtistID: String
    let toArtistID: String
    let kind: Kind
    let evidenceSummaryZh: String
    let sourceRefs: [URL]
    let confidence: Double

    init(id: String, fromArtistID: String, toArtistID: String, kind: Kind, evidenceSummaryZh: String,
         sourceRefs: [URL], confidence: Double = 1) {
        self.id = id; self.fromArtistID = fromArtistID; self.toArtistID = toArtistID; self.kind = kind
        self.evidenceSummaryZh = evidenceSummaryZh; self.sourceRefs = sourceRefs; self.confidence = confidence
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), fromArtistID: try c.decode(String.self, forKey: .fromArtistID),
            toArtistID: try c.decode(String.self, forKey: .toArtistID), kind: try c.decode(Kind.self, forKey: .kind),
            evidenceSummaryZh: try c.decode(String.self, forKey: .evidenceSummaryZh), sourceRefs: try c.decode([URL].self, forKey: .sourceRefs),
            confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1)
    }
}

/// Unlike artist edges, these connections always resolve to museum artwork IDs.
struct ArtworkRelationship: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case sameArtist, sameMovement, influence, sameSeries, thematic, historicalContext
        var isDirected: Bool { self == .influence }
        var displayName: String {
            switch self {
            case .sameArtist: "同一艺术家"
            case .sameMovement: "同一流派"
            case .influence: "影响"
            case .sameSeries: "同一系列"
            case .thematic: "主题关联"
            case .historicalContext: "时代关联"
            }
        }
    }
    let id: String
    let fromArtworkID: String
    let toArtworkID: String
    let kind: Kind
    let evidenceSummaryZh: String
    let sourceRefs: [URL]

    init(id: String, fromArtworkID: String, toArtworkID: String, kind: Kind, evidenceSummaryZh: String, sourceRefs: [URL]) {
        self.id = id; self.fromArtworkID = fromArtworkID; self.toArtworkID = toArtworkID
        self.kind = kind; self.evidenceSummaryZh = evidenceSummaryZh; self.sourceRefs = sourceRefs
    }
}

struct ArtworkAnnotation: Identifiable, Codable, Hashable, Sendable {
    var id: String { artworkID }
    let artworkID: String
    let artistID: String
    let movementIDs: [String]
    let titleZh: String?

    init(artworkID: String, artistID: String, movementIDs: [String], titleZh: String? = nil) {
        self.artworkID = artworkID; self.artistID = artistID; self.movementIDs = movementIDs; self.titleZh = titleZh
    }
}

struct TimelineEvent: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case artistBirth, artistDeath, artworkCreated, movementStarted, movementEnded, historicalContext
    }
    let id: String
    let year: Int
    let endYear: Int?
    let titleZh: String?
    let titleOriginal: String
    let descriptionZh: String?
    let kind: Kind
    let artistIDs: [String]
    let artworkIDs: [String]
    let movementIDs: [String]
    let sourceRefs: [URL]

    init(id: String, year: Int, endYear: Int? = nil, titleZh: String? = nil, titleOriginal: String,
         descriptionZh: String? = nil, kind: Kind = .historicalContext,
         artistIDs: [String] = [], artworkIDs: [String] = [], movementIDs: [String] = [], sourceRefs: [URL]) {
        self.id = id; self.year = year; self.endYear = endYear; self.titleZh = titleZh; self.titleOriginal = titleOriginal
        self.descriptionZh = descriptionZh; self.kind = kind; self.artistIDs = artistIDs; self.artworkIDs = artworkIDs
        self.movementIDs = movementIDs; self.sourceRefs = sourceRefs
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), year: try c.decode(Int.self, forKey: .year),
            endYear: try c.decodeIfPresent(Int.self, forKey: .endYear), titleZh: try c.decodeIfPresent(String.self, forKey: .titleZh),
            titleOriginal: try c.decode(String.self, forKey: .titleOriginal), descriptionZh: try c.decodeIfPresent(String.self, forKey: .descriptionZh),
            kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .historicalContext,
            artistIDs: try c.decodeIfPresent([String].self, forKey: .artistIDs) ?? [], artworkIDs: try c.decodeIfPresent([String].self, forKey: .artworkIDs) ?? [],
            movementIDs: try c.decodeIfPresent([String].self, forKey: .movementIDs) ?? [], sourceRefs: try c.decode([URL].self, forKey: .sourceRefs))
    }

    var displayTitle: String { titleZh?.historyNonempty ?? titleOriginal }
}

struct ArtworkGuideOverlay: Codable, Hashable, Sendable {
    let artworkID: String
    let status: GuideStatus
    let guide: ArtworkGuide
}

enum ArtHistoryNodeID: Hashable, Codable, Sendable {
    case artist(String), movement(String), artwork(String)

    var rawID: String {
        switch self { case .artist(let id), .movement(let id), .artwork(let id): id }
    }
    var stableID: String {
        switch self { case .artist(let id): "artist:\(id)"; case .movement(let id): "movement:\(id)"; case .artwork(let id): "artwork:\(id)" }
    }
}

struct ArtHistorySearchResult: Identifiable, Hashable, Sendable {
    var id: String { target.stableID }
    let target: ArtHistoryNodeID
    let title: String
    let subtitle: String
}

struct ArtHistoryConnection: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case movementArtist, artistArtwork, movementArtwork, movementSequence
        case artistRelationship(ArtistRelationship.Kind), artworkRelationship(ArtworkRelationship.Kind)
    }
    let id: String
    let from: ArtHistoryNodeID
    let to: ArtHistoryNodeID
    let kind: Kind
}

struct ArtHistoryFocus: Equatable, Sendable {
    let nodeIDs: Set<ArtHistoryNodeID>
    let edges: [ArtHistoryConnection]
    let artistRelationshipIDs: Set<String>
    let artworkRelationshipIDs: Set<String>
    static let empty = ArtHistoryFocus(nodeIDs: [], edges: [], artistRelationshipIDs: [], artworkRelationshipIDs: [])
}

struct ArtHistoryDiagnostic: Identifiable, Hashable, Sendable {
    enum Code: String, Hashable, Sendable {
        case missingResource, malformedDocument, unsupportedSchema, malformedRecord, duplicateID
        case invalidReference, invalidYear, missingEvidence, invalidValue, duplicateRelationship, influenceCycle
    }
    var id: String { "\(section):\(recordID):\(code.rawValue):\(message)" }
    let code: Code
    let section: String
    let recordID: String
    let message: String
}

enum HistoryText {
    static func years(_ first: Int?, _ last: Int?) -> String {
        if let first, let last { return first == last ? String(first) : "\(first)–\(last)" }
        if let first { return "\(first)–" }
        if let last { return "–\(last)" }
        return ""
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    fileprivate var historyNonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
