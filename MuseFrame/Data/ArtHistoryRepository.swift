import Foundation

/// A read-only content package. Loading never changes the museum catalog, user store, or shared state.
struct ArtHistoryRepository: Sendable {
    let historyURL: URL?
    let guidesURL: URL?
    private let bundle: Bundle

    init(historyURL: URL? = nil, guidesURL: URL? = nil, bundle: Bundle = MuseFrameResources.bundle) {
        self.historyURL = historyURL; self.guidesURL = guidesURL; self.bundle = bundle
    }

    func load(artworks: [Artwork], invalidatedArtworkIDs: Set<String> = []) -> ArtHistorySnapshot {
        let history = historyURL ?? resource("art_history_curated")
        let guides = guidesURL ?? resource("artwork_guides_zh")
        return Self.decode(historyData: history.flatMap { try? Data(contentsOf: $0) },
            guideData: guides.flatMap { try? Data(contentsOf: $0) }, artworks: artworks,
            invalidatedArtworkIDs: invalidatedArtworkIDs)
    }

    private func resource(_ name: String) -> URL? {
        bundle.url(forResource: name, withExtension: "json", subdirectory: "ArtHistory")
            ?? bundle.url(forResource: name, withExtension: "json")
    }

    /// Records are decoded separately: one damaged item cannot discard the rest of the offline package.
    static func decode(historyData: Data?, guideData: Data?, artworks: [Artwork],
                       invalidatedArtworkIDs: Set<String> = []) -> ArtHistorySnapshot {
        var issues: [ArtHistoryDiagnostic] = []
        let history = document(historyData, section: "history", issues: &issues)
        let guideDocument = document(guideData, section: "guides", issues: &issues)
        let catalog = unique(artworks.filter { !invalidatedArtworkIDs.contains($0.id) }, section: "catalog", issues: &issues)
        let workByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workIDs = Set(workByID.keys)
        let rawMovements: [Movement] = records(history, key: "movements", issues: &issues)
        let rawArtists: [Artist] = records(history, key: "artists", issues: &issues)
        var movements = unique(rawMovements, section: "movements", issues: &issues).filter { movement in
            validBase(movement.id, title: movement.nameOriginal, sources: movement.sourceRefs, section: "movements", issues: &issues)
                && validYears(movement.startYear, movement.endYear, section: "movements", id: movement.id, issues: &issues)
        }
        let movementIDs = Set(movements.map(\.id))
        let artists = unique(rawArtists, section: "artists", issues: &issues).compactMap { artist -> Artist? in
            guard validBase(artist.id, title: artist.nameOriginal, sources: artist.sourceRefs, section: "artists", issues: &issues),
                  validYears(artist.birthYear, artist.deathYear, section: "artists", id: artist.id, issues: &issues) else { return nil }
            guard (1...10).contains(artist.importanceRank) else {
                report(.invalidValue, "artists", artist.id, "importanceRank must be between 1 and 10.", &issues); return nil
            }
            let memberships = references(artist.movementIDs, allowed: movementIDs, section: "artists", id: artist.id, issues: &issues)
            let representatives = references(artist.representativeArtworkIDs, allowed: workIDs, section: "artists", id: artist.id, issues: &issues).filter { id in
                guard let artwork = workByID[id], authorshipMatches(artist, artwork) else {
                    report(.invalidReference, "artists", artist.id, "Representative artwork has a different museum artist: \(id)", &issues); return false
                }
                return true
            }
            let portrait = artist.portraitArtworkID.flatMap { id -> String? in
                guard workIDs.contains(id) else { report(.invalidReference, "artists", artist.id, "Unknown portrait artwork: \(id)", &issues); return nil }
                return id
            }
            return Artist(id: artist.id, nameOriginal: artist.nameOriginal, nameZh: artist.nameZh,
                birthYear: artist.birthYear, deathYear: artist.deathYear, region: artist.region,
                movementIDs: memberships, shortBioZh: artist.shortBioZh, sourceRefs: artist.sourceRefs,
                representativeArtworkIDs: representatives, portraitArtworkID: portrait,
                aliases: artist.aliases, importanceRank: artist.importanceRank)
        }.sorted { ($0.birthYear ?? Int.max, $0.id) < ($1.birthYear ?? Int.max, $1.id) }
        let artistIDs = Set(artists.map(\.id))
        movements = movements.map { movement in
            Movement(id: movement.id, nameOriginal: movement.nameOriginal, nameZh: movement.nameZh,
                startYear: movement.startYear, endYear: movement.endYear, summaryZh: movement.summaryZh, sourceRefs: movement.sourceRefs,
                displayColorToken: movement.displayColorToken, sortOrder: movement.sortOrder,
                keyArtistIDs: references(movement.keyArtistIDs, allowed: artistIDs, section: "movements", id: movement.id, issues: &issues),
                keyArtworkIDs: references(movement.keyArtworkIDs, allowed: workIDs, section: "movements", id: movement.id, issues: &issues),
                previousMovementIDs: references(movement.previousMovementIDs, allowed: movementIDs.subtracting([movement.id]), section: "movements", id: movement.id, issues: &issues),
                nextMovementIDs: references(movement.nextMovementIDs, allowed: movementIDs.subtracting([movement.id]), section: "movements", id: movement.id, issues: &issues))
        }.sorted { ($0.startYear ?? Int.max, $0.sortOrder, $0.id) < ($1.startYear ?? Int.max, $1.sortOrder, $1.id) }
        movements = sanitizedSequences(movements, issues: &issues)

        let rawAnnotations: [ArtworkAnnotation] = records(history, key: "artworkAnnotations", issues: &issues)
        let annotations = unique(rawAnnotations, section: "artworkAnnotations", issues: &issues).compactMap { annotation -> ArtworkAnnotation? in
            guard workIDs.contains(annotation.artworkID), artistIDs.contains(annotation.artistID) else {
                report(.invalidReference, "artworkAnnotations", annotation.artworkID, "Unknown artwork or artist.", &issues); return nil
            }
            if let artist = artists.first(where: { $0.id == annotation.artistID }), let artwork = workByID[annotation.artworkID],
               !authorshipMatches(artist, artwork) {
                report(.invalidReference, "artworkAnnotations", annotation.artworkID, "Annotation conflicts with museum authorship.", &issues); return nil
            }
            return ArtworkAnnotation(artworkID: annotation.artworkID, artistID: annotation.artistID,
                movementIDs: references(annotation.movementIDs, allowed: movementIDs, section: "artworkAnnotations", id: annotation.artworkID, issues: &issues),
                titleZh: annotation.titleZh)
        }
        let annotationByID = Dictionary(annotations.map { ($0.artworkID, $0) }, uniquingKeysWith: { first, _ in first })
        let rawArtistEdges: [ArtistRelationship] = records(history, key: "artistRelationships", issues: &issues)
        var artistGraph: [String: Set<String>] = [:]
        var artistEdgeKeys: Set<String> = []
        let artistEdges = unique(rawArtistEdges, section: "artistRelationships", issues: &issues).sorted { $0.id < $1.id }.filter { edge in
            guard validBase(edge.id, title: edge.evidenceSummaryZh, sources: edge.sourceRefs, section: "artistRelationships", issues: &issues) else { return false }
            guard artistIDs.contains(edge.fromArtistID), artistIDs.contains(edge.toArtistID), edge.fromArtistID != edge.toArtistID else {
                report(.invalidReference, "artistRelationships", edge.id, "Unknown or self-referencing artist endpoint.", &issues); return false
            }
            guard edge.confidence.isFinite, (0...1).contains(edge.confidence) else {
                report(.invalidValue, "artistRelationships", edge.id, "Confidence must be between 0 and 1.", &issues); return false
            }
            let key = relationshipKey(edge.fromArtistID, edge.toArtistID, kind: edge.kind.rawValue, directed: edge.kind.isDirected)
            guard artistEdgeKeys.insert(key).inserted else {
                report(.duplicateRelationship, "artistRelationships", edge.id, "Repeated artist relationship.", &issues); return false
            }
            if edge.kind.isDirected {
                guard !reaches(edge.fromArtistID, from: edge.toArtistID, graph: artistGraph) else {
                    report(.influenceCycle, "artistRelationships", edge.id, "Directed influence/teaching cycle omitted.", &issues); return false
                }
                artistGraph[edge.fromArtistID, default: []].insert(edge.toArtistID)
            }
            return true
        }
        let rawArtworkEdges: [ArtworkRelationship] = records(history, key: "artworkRelationships", issues: &issues)
        var artworkGraph: [String: Set<String>] = [:]
        var artworkEdgeKeys: Set<String> = []
        let artworkEdges = unique(rawArtworkEdges, section: "artworkRelationships", issues: &issues).sorted { $0.id < $1.id }.filter { edge in
            guard validBase(edge.id, title: edge.evidenceSummaryZh, sources: edge.sourceRefs, section: "artworkRelationships", issues: &issues) else { return false }
            guard let first = workByID[edge.fromArtworkID], let second = workByID[edge.toArtworkID], first.id != second.id else {
                report(.invalidReference, "artworkRelationships", edge.id, "Unknown or self-referencing artwork endpoint.", &issues); return false
            }
            if edge.kind == .sameArtist {
                let leftArtist = annotationByID[first.id]?.artistID ?? first.artistID
                let rightArtist = annotationByID[second.id]?.artistID ?? second.artistID
                let same = leftArtist != nil && rightArtist != nil ? leftArtist == rightArtist
                    : HistoryText.normalized(first.artistOriginal) == HistoryText.normalized(second.artistOriginal)
                guard same else { report(.invalidReference, "artworkRelationships", edge.id, "sameArtist endpoints have different artists.", &issues); return false }
            }
            if edge.kind == .sameMovement {
                let firstMovements = Set(annotationByID[first.id]?.movementIDs ?? [])
                let secondMovements = Set(annotationByID[second.id]?.movementIDs ?? [])
                let same = !firstMovements.intersection(secondMovements).isEmpty
                    || (!first.movement.isEmpty && first.movement != "Other" && first.movement == second.movement)
                guard same else { report(.invalidReference, "artworkRelationships", edge.id, "sameMovement endpoints share no known movement.", &issues); return false }
            }
            let key = relationshipKey(first.id, second.id, kind: edge.kind.rawValue, directed: edge.kind.isDirected)
            guard artworkEdgeKeys.insert(key).inserted else {
                report(.duplicateRelationship, "artworkRelationships", edge.id, "Repeated artwork relationship.", &issues); return false
            }
            if edge.kind.isDirected {
                guard !reaches(first.id, from: second.id, graph: artworkGraph) else {
                    report(.influenceCycle, "artworkRelationships", edge.id, "Directed artwork influence cycle omitted.", &issues); return false
                }
                artworkGraph[first.id, default: []].insert(second.id)
            }
            return true
        }
        let rawEvents: [TimelineEvent] = records(history, key: "timelineEvents", issues: &issues)
        let events = unique(rawEvents, section: "timelineEvents", issues: &issues).filter { event in
            guard validBase(event.id, title: event.titleOriginal, sources: event.sourceRefs, section: "timelineEvents", issues: &issues),
                  validYears(event.year, event.endYear, section: "timelineEvents", id: event.id, issues: &issues) else { return false }
            guard Set(event.artistIDs).isSubset(of: artistIDs), Set(event.artworkIDs).isSubset(of: workIDs),
                  Set(event.movementIDs).isSubset(of: movementIDs) else {
                report(.invalidReference, "timelineEvents", event.id, "Unknown artist, movement, or artwork.", &issues); return false
            }
            return true
        }.sorted { ($0.year, $0.endYear ?? $0.year, $0.id) < ($1.year, $1.endYear ?? $1.year, $1.id) }
        let rawGuides: [ArtworkGuideOverlay] = records(guideDocument, key: "guides", issues: &issues)
        var guideOverlays: [String: ArtworkGuideOverlay] = [:]
        for overlay in rawGuides {
            guard workIDs.contains(overlay.artworkID) else {
                report(.invalidReference, "guides", overlay.artworkID, "Unknown or withdrawn artwork.", &issues); continue
            }
            guard guideOverlays[overlay.artworkID] == nil else {
                report(.duplicateID, "guides", overlay.artworkID, "Duplicate guide artworkID.", &issues); continue
            }
            let guide = overlay.guide
            guard validSources(guide.sourceRefs) else {
                report(.missingEvidence, "guides", overlay.artworkID, "Guide requires HTTPS source references.", &issues); continue
            }
            guard guide.editorialVersion > 0, !guide.summary30s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                report(.invalidValue, "guides", overlay.artworkID, "Empty introduction or invalid editorial version.", &issues); continue
            }
            if overlay.status == .published {
                let points = guide.lookAtPoints.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard points.count >= 2, guide.story?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      guide.importance?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    report(.invalidValue, "guides", overlay.artworkID, "Published guides require context, two observation points, and significance.", &issues); continue
                }
            }
            guideOverlays[overlay.artworkID] = overlay
        }
        return ArtHistorySnapshot(contentVersion: history?["contentVersion"] as? String ?? "",
            artists: artists, movements: movements, artistRelationships: artistEdges, artworkRelationships: artworkEdges,
            timelineEvents: events, artworkAnnotations: annotations, guideOverlays: guideOverlays,
            diagnostics: issues, catalog: catalog)
    }

    private struct Header: Decodable { let schemaVersion: Int; let contentVersion: String }
    private static func document(_ data: Data?, section: String, issues: inout [ArtHistoryDiagnostic]) -> [String: Any]? {
        guard let data else { report(.missingResource, section, "", "Offline content resource is unavailable.", &issues); return nil }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.schemaVersion == 1 else {
                report(.unsupportedSchema, section, "", "Unsupported content schema: \(header.schemaVersion)", &issues); return nil
            }
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            return document
        } catch { report(.malformedDocument, section, "", "Content document cannot be decoded.", &issues); return nil }
    }

    private static func records<T: Decodable>(_ document: [String: Any]?, key: String, issues: inout [ArtHistoryDiagnostic]) -> [T] {
        guard let document else { return [] }
        guard let value = document[key] else { return [] }
        guard let items = value as? [Any] else { report(.malformedRecord, key, "", "Expected a record array.", &issues); return [] }
        return items.enumerated().compactMap { index, item in
            do {
                let data = try JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed])
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                let id = (item as? [String: Any])?["id"] as? String ?? String(index)
                report(.malformedRecord, key, id, "Record cannot be decoded.", &issues); return nil
            }
        }
    }

    private static func unique<T: Identifiable>(_ records: [T], section: String, issues: inout [ArtHistoryDiagnostic]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return records.filter { record in
            guard seen.insert(record.id).inserted else { report(.duplicateID, section, record.id, "Duplicate ID omitted.", &issues); return false }
            return true
        }
    }

    private static func validBase(_ id: String, title: String, sources: [URL], section: String, issues: inout [ArtHistoryDiagnostic]) -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report(.invalidValue, section, id, "Empty identifier or label/evidence.", &issues); return false
        }
        guard validSources(sources) else { report(.missingEvidence, section, id, "HTTPS source references are required.", &issues); return false }
        return true
    }

    private static func validSources(_ sources: [URL]) -> Bool {
        !sources.isEmpty && sources.allSatisfy { $0.scheme?.lowercased() == "https" && $0.host?.isEmpty == false && $0.user == nil && $0.password == nil }
    }

    private static func validYears(_ first: Int?, _ last: Int?, section: String, id: String, issues: inout [ArtHistoryDiagnostic]) -> Bool {
        let ordered: Bool
        if let first, let last { ordered = first <= last } else { ordered = true }
        guard [first, last].compactMap({ $0 }).allSatisfy({ (-10_000...2100).contains($0) }),
              ordered else {
            report(.invalidYear, section, id, "Invalid or reversed year range.", &issues); return false
        }
        return true
    }

    private static func authorshipMatches(_ artist: Artist, _ artwork: Artwork) -> Bool {
        artist.id == artwork.artistID || ([artist.nameOriginal] + artist.aliases).contains {
            HistoryText.normalized($0) == HistoryText.normalized(artwork.artistOriginal)
        }
    }

    /// A previous/next pair is one chronological direction, rather than two reciprocal influence edges.
    private static func sanitizedSequences(_ movements: [Movement], issues: inout [ArtHistoryDiagnostic]) -> [Movement] {
        let byID = Dictionary(movements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates = Set<[String]>()
        for movement in movements {
            for next in movement.nextMovementIDs { candidates.insert([movement.id, next]) }
            for previous in movement.previousMovementIDs { candidates.insert([previous, movement.id]) }
        }
        var graph: [String: Set<String>] = [:]
        var allowed = Set<[String]>()
        for pair in candidates.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            if let first = byID[pair[0]]?.startYear, let last = byID[pair[1]]?.startYear, first > last {
                report(.invalidYear, "movements", pair[0], "Movement sequence runs backwards: \(pair[1])", &issues); continue
            }
            guard !reaches(pair[0], from: pair[1], graph: graph) else {
                report(.influenceCycle, "movements", pair[0], "Cyclic movement sequence omitted: \(pair[1])", &issues); continue
            }
            allowed.insert(pair); graph[pair[0], default: []].insert(pair[1])
        }
        return movements.map { movement in
            Movement(id: movement.id, nameOriginal: movement.nameOriginal, nameZh: movement.nameZh,
                startYear: movement.startYear, endYear: movement.endYear, summaryZh: movement.summaryZh,
                sourceRefs: movement.sourceRefs, displayColorToken: movement.displayColorToken, sortOrder: movement.sortOrder,
                keyArtistIDs: movement.keyArtistIDs, keyArtworkIDs: movement.keyArtworkIDs,
                previousMovementIDs: movement.previousMovementIDs.filter { allowed.contains([$0, movement.id]) },
                nextMovementIDs: movement.nextMovementIDs.filter { allowed.contains([movement.id, $0]) })
        }
    }

    private static func references(_ values: [String], allowed: Set<String>, section: String, id: String, issues: inout [ArtHistoryDiagnostic]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard allowed.contains(value) else { report(.invalidReference, section, id, "Unknown reference: \(value)", &issues); return false }
            return seen.insert(value).inserted
        }
    }

    private static func relationshipKey(_ first: String, _ last: String, kind: String, directed: Bool) -> String {
        let pair = directed ? [first, last] : [first, last].sorted()
        return "\(kind)|\(pair[0])|\(pair[1])"
    }

    private static func reaches(_ target: String, from start: String, graph: [String: Set<String>]) -> Bool {
        var pending = [start], visited = Set<String>()
        while let current = pending.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted else { continue }
            pending.append(contentsOf: graph[current] ?? [])
        }
        return false
    }

    private static func report(_ code: ArtHistoryDiagnostic.Code, _ section: String, _ recordID: String,
                               _ message: String, _ issues: inout [ArtHistoryDiagnostic]) {
        issues.append(ArtHistoryDiagnostic(code: code, section: section, recordID: recordID, message: message))
    }
}

struct ArtHistorySnapshot: Sendable {
    let contentVersion: String
    let artists: [Artist]
    let movements: [Movement]
    let artistRelationships: [ArtistRelationship]
    let artworkRelationships: [ArtworkRelationship]
    let timelineEvents: [TimelineEvent]
    let artworkAnnotations: [ArtworkAnnotation]
    let guideOverlays: [String: ArtworkGuideOverlay]
    let diagnostics: [ArtHistoryDiagnostic]
    private let catalog: [Artwork]

    static let empty = ArtHistorySnapshot(contentVersion: "", artists: [], movements: [], artistRelationships: [],
        artworkRelationships: [], timelineEvents: [], artworkAnnotations: [], guideOverlays: [:], diagnostics: [], catalog: [])

    init(contentVersion: String, artists: [Artist], movements: [Movement], artistRelationships: [ArtistRelationship],
         artworkRelationships: [ArtworkRelationship], timelineEvents: [TimelineEvent], artworkAnnotations: [ArtworkAnnotation],
         guideOverlays: [String: ArtworkGuideOverlay], diagnostics: [ArtHistoryDiagnostic], catalog: [Artwork]) {
        self.contentVersion = contentVersion; self.artists = artists; self.movements = movements
        self.artistRelationships = artistRelationships; self.artworkRelationships = artworkRelationships
        self.timelineEvents = timelineEvents; self.artworkAnnotations = artworkAnnotations
        self.guideOverlays = guideOverlays; self.diagnostics = diagnostics; self.catalog = catalog
    }

    /// Only the curated core is offered on the history canvas; Gallery retains the whole catalog.
    var coreArtworkIDs: Set<String> {
        var ids = Set(artworkAnnotations.map(\.artworkID))
        for artist in artists { ids.formUnion(artist.representativeArtworkIDs) }
        for movement in movements { ids.formUnion(movement.keyArtworkIDs) }
        for event in timelineEvents { ids.formUnion(event.artworkIDs) }
        for edge in artworkRelationships { ids.insert(edge.fromArtworkID); ids.insert(edge.toArtworkID) }
        return ids
    }
    var artworks: [Artwork] {
        let ids = coreArtworkIDs
        return catalog.filter { ids.contains($0.id) }.map { applyingEditorialOverlay(to: $0) }
    }

    func artist(id: String) -> Artist? { artists.first { $0.id == id } }
    func movement(id: String) -> Movement? { movements.first { $0.id == id } }
    func artwork(id: String) -> Artwork? { catalog.first { $0.id == id }.map { applyingEditorialOverlay(to: $0) } }
    func artist(for artworkID: String) -> Artist? {
        if let annotation = artworkAnnotations.first(where: { $0.artworkID == artworkID }) { return artist(id: annotation.artistID) }
        if let representative = artists.first(where: { $0.representativeArtworkIDs.contains(artworkID) }) { return representative }
        guard let artwork = catalog.first(where: { $0.id == artworkID }) else { return nil }
        return artists.first { artist in
            artist.id == artwork.artistID || HistoryText.normalized(artist.nameOriginal) == HistoryText.normalized(artwork.artistOriginal)
                || artist.aliases.contains { HistoryText.normalized($0) == HistoryText.normalized(artwork.artistOriginal) }
        }
    }
    func movements(for artworkID: String) -> [Movement] {
        if let annotation = artworkAnnotations.first(where: { $0.artworkID == artworkID }) {
            return annotation.movementIDs.compactMap { movement(id: $0) }
        }
        if let artist = artist(for: artworkID) { return artist.movementIDs.compactMap { movement(id: $0) } }
        guard let artwork = catalog.first(where: { $0.id == artworkID }) else { return [] }
        return movements.filter { HistoryText.normalized($0.nameOriginal) == HistoryText.normalized(artwork.movement) }
    }
    func artworks(for artistID: String) -> [Artwork] {
        var ids = Set(artist(id: artistID)?.representativeArtworkIDs ?? [])
        ids.formUnion(artworkAnnotations.filter { $0.artistID == artistID }.map(\.artworkID))
        return catalog.filter { ids.contains($0.id) }.map { applyingEditorialOverlay(to: $0) }
    }

    /// Add Chinese editorial content without changing source identities, filter keys, image data, or rights.
    func applyingEditorialOverlay(to artwork: Artwork) -> Artwork {
        let annotation = artworkAnnotations.first { $0.artworkID == artwork.id }
        let author = artist(for: artwork.id)
        let overlay = guideOverlays[artwork.id]
        let published = overlay?.status == .published ? overlay?.guide : nil
        let usePublication = published.map { !artwork.hasPublishedGuide || (artwork.guide?.editorialVersion ?? 0) <= $0.editorialVersion } ?? false
        let guide = usePublication ? published : artwork.guide
        let status: GuideStatus = usePublication ? .published : artwork.guideStatus
        return Artwork(id: artwork.id, source: artwork.source, sourceID: artwork.sourceID, titleOriginal: artwork.titleOriginal,
            titleZh: annotation?.titleZh ?? artwork.titleZh, artistOriginal: artwork.artistOriginal, artistZh: author?.nameZh ?? artwork.artistZh,
            dateDisplay: artwork.dateDisplay, yearStart: artwork.yearStart, movement: artwork.movement, movementZh: artwork.movementZh,
            themes: artwork.themes, medium: artwork.medium, dimensions: artwork.dimensions, museumName: artwork.museumName,
            sourceURL: artwork.sourceURL, image: artwork.image, isPublicDomain: artwork.isPublicDomain,
            metadataLicense: artwork.metadataLicense, guideStatus: status, dominantColors: artwork.dominantColors,
            guide: guide, artistID: artwork.artistID, yearEnd: artwork.yearEnd, metadataUpdatedAt: artwork.metadataUpdatedAt)
    }

    func search(query: String, limit: Int = 12) -> [ArtHistorySearchResult] {
        let query = HistoryText.normalized(query)
        guard !query.isEmpty, limit > 0 else { return [] }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var candidates: [(ArtHistorySearchResult, String, String)] = []
        for movement in movements {
            candidates.append((ArtHistorySearchResult(target: .movement(movement.id), title: movement.displayName,
                subtitle: movement.yearsDisplay), movement.nameOriginal + " " + (movement.nameZh ?? ""), movement.displayName))
        }
        for artist in artists {
            candidates.append((ArtHistorySearchResult(target: .artist(artist.id), title: artist.displayName,
                subtitle: artist.yearsDisplay), artist.searchText, artist.displayName))
        }
        for artwork in artworks {
            candidates.append((ArtHistorySearchResult(target: .artwork(artwork.id), title: artwork.displayTitle,
                subtitle: artwork.displayArtist + " · " + artwork.dateDisplay),
                [artwork.titleOriginal, artwork.titleZh ?? "", artwork.artistOriginal, artwork.artistZh ?? ""].joined(separator: " "), artwork.displayTitle))
        }
        return candidates.compactMap { result, searchable, title -> (ArtHistorySearchResult, Int)? in
            let text = HistoryText.normalized(searchable)
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            let title = HistoryText.normalized(title)
            let rank = title == query ? 0 : title.hasPrefix(query) ? 1 : title.contains(query) ? 2 : 3
            return (result, rank)
        }.sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }.prefix(min(limit, 100)).map(\.0)
    }

    /// Structural membership comes only from the validated package. Edges are not inferred from proximity.
    func connections(relationshipKind: ArtistRelationship.Kind? = nil) -> [ArtHistoryConnection] {
        var edges: [ArtHistoryConnection] = []
        var seen = Set<String>()
        func append(_ from: ArtHistoryNodeID, _ to: ArtHistoryNodeID, _ kind: ArtHistoryConnection.Kind, id: String) {
            guard seen.insert(id).inserted else { return }
            edges.append(ArtHistoryConnection(id: id, from: from, to: to, kind: kind))
        }
        for artist in artists {
            for movementID in artist.movementIDs {
                append(.movement(movementID), .artist(artist.id), .movementArtist, id: "membership:\(movementID):\(artist.id)")
            }
        }
        for artwork in artworks {
            if let artist = artist(for: artwork.id) {
                append(.artist(artist.id), .artwork(artwork.id), .artistArtwork, id: "authorship:\(artist.id):\(artwork.id)")
            }
            for movement in movements(for: artwork.id) {
                append(.movement(movement.id), .artwork(artwork.id), .movementArtwork, id: "artwork-movement:\(movement.id):\(artwork.id)")
            }
        }
        for movement in movements {
            for next in movement.nextMovementIDs {
                append(.movement(movement.id), .movement(next), .movementSequence, id: "sequence:\(movement.id):\(next)")
            }
            for previous in movement.previousMovementIDs {
                append(.movement(previous), .movement(movement.id), .movementSequence, id: "sequence:\(previous):\(movement.id)")
            }
        }
        for edge in artistRelationships where relationshipKind == nil || relationshipKind == edge.kind {
            append(.artist(edge.fromArtistID), .artist(edge.toArtistID), .artistRelationship(edge.kind), id: "artist-edge:\(edge.id)")
        }
        for edge in artworkRelationships {
            append(.artwork(edge.fromArtworkID), .artwork(edge.toArtworkID), .artworkRelationship(edge.kind), id: "artwork-edge:\(edge.id)")
        }
        return edges.sorted { $0.id < $1.id }
    }

    func focus(on target: ArtHistoryNodeID, relationshipKind: ArtistRelationship.Kind? = nil) -> ArtHistoryFocus {
        switch target {
        case .artist(let id): guard artist(id: id) != nil else { return .empty }
        case .movement(let id): guard movement(id: id) != nil else { return .empty }
        case .artwork(let id): guard coreArtworkIDs.contains(id) else { return .empty }
        }
        let edges = connections(relationshipKind: relationshipKind).filter { $0.from == target || $0.to == target }
        var nodeIDs: Set<ArtHistoryNodeID> = [target]
        for edge in edges { nodeIDs.insert(edge.from); nodeIDs.insert(edge.to) }
        let artistIDs = Set(edges.compactMap { edge -> String? in
            if case .artistRelationship = edge.kind { return String(edge.id.dropFirst("artist-edge:".count)) }
            return nil
        })
        let artworkIDs = Set(edges.compactMap { edge -> String? in
            if case .artworkRelationship = edge.kind { return String(edge.id.dropFirst("artwork-edge:".count)) }
            return nil
        })
        return ArtHistoryFocus(nodeIDs: nodeIDs, edges: edges, artistRelationshipIDs: artistIDs, artworkRelationshipIDs: artworkIDs)
    }
}
