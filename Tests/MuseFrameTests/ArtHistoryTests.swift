import Foundation
import Testing
@testable import MuseFrame

@Suite("Offline art history, guides, and focus")
struct ArtHistoryTests {
    @Test func missingOrDamagedHistoryRetainsIndependentlyReadableGuides() throws {
        for damaged in [nil, Data("{unfinished".utf8), Data("[]".utf8)] {
            let snapshot = ArtHistoryRepository.decode(historyData: damaged, guideData: try guideData([overlay()]), artworks: works())
            #expect(snapshot.artists.isEmpty)
            #expect(snapshot.guideOverlays.count == 1)
            #expect(snapshot.artwork(id: "work-one")?.hasPublishedGuide == true)
            #expect(!snapshot.diagnostics.isEmpty)
        }
    }

    @Test func unsupportedSchemaIsReadOnlyAndDoesNotBreakTheMuseumCatalog() throws {
        var package = HistoryPackage()
        package.schemaVersion = 99
        let data = try JSONEncoder().encode(package)
        let snapshot = ArtHistoryRepository.decode(historyData: data, guideData: try guideData([]), artworks: works())
        #expect(snapshot.artists.isEmpty)
        #expect(snapshot.artwork(id: "work-one")?.titleOriginal == "River in the Morning")
        #expect(snapshot.diagnostics.contains { $0.code == .unsupportedSchema })
    }

    @Test func malformedRecordIsSkippedWithoutDiscardingValidSiblings() throws {
        var root = try #require(JSONSerialization.jsonObject(with: historyData()) as? [String: Any])
        root["artists"] = [try object(artist("a")), ["id": "bad", "nameOriginal": 42], "not an artist"]
        let snapshot = ArtHistoryRepository.decode(historyData: try JSONSerialization.data(withJSONObject: root),
            guideData: try guideData([]), artworks: works())
        #expect(snapshot.artists.map(\.id) == ["a"])
        #expect(snapshot.diagnostics.filter { $0.code == .malformedRecord }.count == 2)
    }

    @Test func duplicateIDsAndDanglingReferencesAreSanitizedWithoutDictionaryTraps() throws {
        let invalid = Artist(id: "a", nameOriginal: "Duplicate", movementIDs: [], sourceRefs: sources)
        let partial = Artist(id: "b", nameOriginal: "Artist B", movementIDs: ["m", "missing"], sourceRefs: sources,
            representativeArtworkIDs: ["work-two", "not-in-seed"], portraitArtworkID: "missing")
        let snapshot = try load(artists: [artist("a"), invalid, partial],
            annotations: [annotation("work-one", "a"), annotation("missing", "b")])
        #expect(snapshot.artists.count == 2)
        #expect(snapshot.artist(id: "a")?.nameOriginal == "Artist A")
        #expect(snapshot.artist(id: "b")?.movementIDs == ["m"])
        #expect(snapshot.artist(id: "b")?.representativeArtworkIDs == ["work-two"])
        #expect(snapshot.artist(id: "b")?.portraitArtworkID == nil)
        #expect(snapshot.artworkAnnotations.count == 1)
        #expect(snapshot.diagnostics.contains { $0.code == .duplicateID })
        #expect(snapshot.diagnostics.contains { $0.code == .invalidReference })
    }

    @Test func reversedAndExtremeYearsAreRejectedButUnknownDatesRemainUnknown() throws {
        let reversed = Artist(id: "reversed", nameOriginal: "Wrong", birthYear: 1900, deathYear: 1800, sourceRefs: sources)
        let extreme = Artist(id: "extreme", nameOriginal: "Wrong", birthYear: Int.max, sourceRefs: sources)
        let unknown = Artist(id: "unknown", nameOriginal: "Unknown dates", sourceRefs: sources)
        let snapshot = try load(artists: [reversed, extreme, unknown])
        #expect(snapshot.artists.map(\.id) == ["unknown"])
        #expect(snapshot.artist(id: "unknown")?.birthYear == nil)
        #expect(snapshot.artist(id: "unknown")?.yearsDisplay == "")
        #expect(Artist(id: "partial", nameOriginal: "Partial dates", deathYear: 1506, sourceRefs: sources).yearsDisplay == "卒于 1506")
        #expect(snapshot.diagnostics.filter { $0.code == .invalidYear }.count == 2)
    }

    @Test func curatedMembershipCannotOverrideMuseumAuthorship() throws {
        let wrongArtist = Artist(id: "b", nameOriginal: "Artist B", sourceRefs: sources, representativeArtworkIDs: ["work-one"])
        let snapshot = try load(artists: [artist("a"), wrongArtist], annotations: [annotation("work-one", "b")])
        #expect(snapshot.artist(id: "b")?.representativeArtworkIDs.isEmpty == true)
        #expect(snapshot.artworkAnnotations.isEmpty)
        #expect(snapshot.artist(for: "work-one")?.id == "a")
        #expect(snapshot.diagnostics.filter { $0.code == .invalidReference }.count == 2)
    }

    @Test func movementSequenceDeduplicatesReciprocalMembershipAndPrunesCyclesAndBackwardsDates() throws {
        let first = Movement(id: "m1", nameOriginal: "First", startYear: 1800, sourceRefs: sources, nextMovementIDs: ["m2"])
        let second = Movement(id: "m2", nameOriginal: "Second", startYear: 1800, sourceRefs: sources,
            previousMovementIDs: ["m1"], nextMovementIDs: ["m1"])
        let late = Movement(id: "late", nameOriginal: "Late", startYear: 1900, sourceRefs: sources, nextMovementIDs: ["m1"])
        let snapshot = try load(artists: [], movements: [first, second, late])
        let sequences = snapshot.connections().filter { $0.kind == .movementSequence }
        #expect(sequences.count == 1)
        #expect(sequences.first?.from == .movement("m1"))
        #expect(sequences.first?.to == .movement("m2"))
        #expect(snapshot.diagnostics.contains { $0.code == .influenceCycle })
        #expect(snapshot.diagnostics.contains { $0.code == .invalidYear })
    }

    @Test func missingEvidenceCannotBecomeAnArtistOrRelationship() throws {
        let noSources = Artist(id: "no-sources", nameOriginal: "No evidence", sourceRefs: [])
        let insecure = Artist(id: "insecure", nameOriginal: "Wrong URL", sourceRefs: [URL(string: "file:///tmp/private")!])
        let edge = ArtistRelationship(id: "unsupported", fromArtistID: "a", toArtistID: "b", kind: .influence,
            evidenceSummaryZh: "A claim without a reference", sourceRefs: [])
        let snapshot = try load(artists: [artist("a"), artist("b"), noSources, insecure], artistEdges: [edge])
        #expect(snapshot.artists.count == 2)
        #expect(snapshot.artistRelationships.isEmpty)
        #expect(snapshot.diagnostics.filter { $0.code == .missingEvidence }.count == 3)
    }

    @Test func reversedUndirectedDuplicatesAreRemovedButDistinctRelationshipTypesRemain() throws {
        let snapshot = try load(artistEdges: [edge("1", "a", "b", .crossedPaths), edge("2", "b", "a", .crossedPaths),
            edge("3", "a", "b", .parallelPaths)])
        #expect(snapshot.artistRelationships.map(\.id) == ["1", "3"])
        #expect(snapshot.diagnostics.contains { $0.code == .duplicateRelationship })
    }

    @Test func directedInfluenceAndTeachingCycleIsPrunedDeterministically() throws {
        let edges = [edge("1", "a", "b", .teacherStudent), edge("2", "b", "c", .influence), edge("3", "c", "a", .influence)]
        let first = try load(artistEdges: edges)
        let reversed = try load(artistEdges: Array(edges.reversed()))
        #expect(first.artistRelationships.map(\.id) == ["1", "2"])
        #expect(first.artistRelationships == reversed.artistRelationships)
        #expect(first.diagnostics.contains { $0.code == .influenceCycle })
    }

    @Test func selfEdgesUnknownTargetsAndInvalidConfidenceCannotEnterFocus() throws {
        let invalid = ArtistRelationship(id: "confidence", fromArtistID: "a", toArtistID: "b", kind: .influence,
            evidenceSummaryZh: "Test", sourceRefs: sources, confidence: 2)
        let snapshot = try load(artistEdges: [edge("self", "a", "a"), edge("missing", "a", "missing"), invalid])
        #expect(snapshot.artistRelationships.isEmpty)
        #expect(snapshot.focus(on: .artist("a")).artistRelationshipIDs.isEmpty)
    }

    @Test func artworkEdgesResolveArtworkIDsAndVerifySameArtistClaim() throws {
        let one = ArtworkRelationship(id: "1", fromArtworkID: "work-one", toArtworkID: "work-two", kind: .sameArtist,
            evidenceSummaryZh: "Incorrect authorship", sourceRefs: sources)
        let two = ArtworkRelationship(id: "2", fromArtworkID: "work-one", toArtworkID: "work-two", kind: .thematic,
            evidenceSummaryZh: "Independent visual comparison", sourceRefs: sources)
        let three = ArtworkRelationship(id: "3", fromArtworkID: "work-two", toArtworkID: "work-one", kind: .thematic,
            evidenceSummaryZh: "Repeated comparison", sourceRefs: sources)
        let missing = ArtworkRelationship(id: "4", fromArtworkID: "a", toArtworkID: "work-two", kind: .historicalContext,
            evidenceSummaryZh: "Artist ID cannot be used as an artwork endpoint", sourceRefs: sources)
        let snapshot = try load(artworkEdges: [one, two, three, missing])
        #expect(snapshot.artworkRelationships.map(\.id) == ["2"])
        #expect(snapshot.focus(on: .artwork("work-one")).artworkRelationshipIDs == ["2"])
    }

    @Test func directedArtworkInfluenceCycleIsOmitted() throws {
        let edges = [("1", "work-one", "work-two"), ("2", "work-two", "work-three"), ("3", "work-three", "work-one")].map {
            ArtworkRelationship(id: $0.0, fromArtworkID: $0.1, toArtworkID: $0.2, kind: .influence,
                evidenceSummaryZh: "Referenced relation", sourceRefs: sources)
        }
        let snapshot = try load(artworkEdges: edges)
        #expect(snapshot.artworkRelationships.map(\.id) == ["1", "2"])
        #expect(snapshot.diagnostics.contains { $0.code == .influenceCycle })
    }

    @Test func timelineUsesTrueYearThenEndYearAndStableIDForTies() throws {
        let events = [event("z", 1900), event("a", 1900), event("early", 1850),
            TimelineEvent(id: "range", year: 1900, endYear: 1910, titleOriginal: "Range", sourceRefs: sources),
            TimelineEvent(id: "bad-range", year: 1900, endYear: 1800, titleOriginal: "Invalid", sourceRefs: sources),
            TimelineEvent(id: "bad-ref", year: 1890, titleOriginal: "Invalid", artworkIDs: ["missing"], sourceRefs: sources)]
        let snapshot = try load(events: events)
        #expect(snapshot.timelineEvents.map(\.id) == ["early", "a", "z", "range"])
        #expect(snapshot.diagnostics.contains { $0.code == .invalidYear })
        #expect(snapshot.diagnostics.contains { $0.code == .invalidReference })
    }

    @Test func publishedGuideRequiresContextObservationSignificanceAndSources() throws {
        let incomplete = ArtworkGuide(summary30s: "Introduction", lookAtPoints: ["One point"], sourceRefs: sources)
        let snapshot = try load(guides: [ArtworkGuideOverlay(artworkID: "work-one", status: .published, guide: incomplete)])
        #expect(snapshot.guideOverlays.isEmpty)
        #expect(snapshot.artwork(id: "work-one")?.hasPublishedGuide == false)
        #expect(snapshot.diagnostics.contains { $0.code == .invalidValue })
    }

    @Test func draftGuideDoesNotEnableWithGuideOrReplaceExistingPublishedContent() throws {
        let published = works()[0]
        let work = Artwork(id: published.id, source: published.source, sourceID: published.sourceID,
            titleOriginal: published.titleOriginal, artistOriginal: published.artistOriginal, dateDisplay: published.dateDisplay,
            museumName: published.museumName, sourceURL: published.sourceURL, image: published.image, isPublicDomain: true,
            guideStatus: .published, guide: guide(summary: "Existing publication"))
        let draft = ArtworkGuideOverlay(artworkID: work.id, status: .draft, guide: guide(summary: "New draft"))
        let snapshot = try load(guides: [draft], catalog: [work])
        #expect(snapshot.artwork(id: work.id)?.guide?.summary30s == "Existing publication")
        #expect(snapshot.artwork(id: work.id)?.hasPublishedGuide == true)
    }

    @Test func editorialOverlayChangesOnlyChineseLabelsAndPublishedGuide() throws {
        let original = works()[0]
        let snapshot = try load(annotations: [ArtworkAnnotation(artworkID: original.id, artistID: "a", movementIDs: ["m"], titleZh: "清晨的河流")],
            guides: [overlay()])
        let enriched = try #require(snapshot.artwork(id: original.id))
        #expect(enriched.titleZh == "清晨的河流")
        #expect(enriched.artistZh == "艺术家 A")
        #expect(enriched.hasPublishedGuide)
        var before = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var after = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(enriched)) as? [String: Any])
        for key in ["titleZh", "artistZh", "guide", "guideStatus"] { before.removeValue(forKey: key); after.removeValue(forKey: key) }
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }

    @Test func invalidatedArtworkCannotBeRestoredByGuideAnnotationOrRelationship() throws {
        let snapshot = try load(annotations: [annotation("work-one", "a")], guides: [overlay()], invalidated: ["work-one"])
        #expect(snapshot.artwork(id: "work-one") == nil)
        #expect(snapshot.guideOverlays["work-one"] == nil)
        #expect(!snapshot.coreArtworkIDs.contains("work-one"))
        #expect(snapshot.focus(on: .artwork("work-one")) == .empty)
    }

    @Test func searchLocatesChineseAliasesAccentsMovementsAndArtworkTitles() throws {
        let monet = Artist(id: "a", nameOriginal: "Claude Monet", nameZh: "克劳德·莫奈", birthYear: 1840, deathYear: 1926,
            movementIDs: ["m"], sourceRefs: sources, representativeArtworkIDs: ["work-one"], aliases: ["Monet", "莫内", "Cláude"])
        let snapshot = try load(artists: [monet])
        #expect(snapshot.search(query: "莫内").first?.target == .artist("a"))
        #expect(snapshot.search(query: "CLAUDE").contains { $0.target == .artist("a") })
        #expect(snapshot.search(query: "Impressionism").first?.target == .movement("m"))
        #expect(snapshot.search(query: "River Morning").first?.target == .artwork("work-one"))
        #expect(snapshot.search(query: "   ").isEmpty)
        #expect(snapshot.search(query: "Artist", limit: 0).isEmpty)
    }

    @Test func focusIncludesOnlySelectedNodeAndItsImmediateValidatedNeighbors() throws {
        let snapshot = try load(artistEdges: [edge("ab", "a", "b"), edge("bc", "b", "c")])
        let focus = snapshot.focus(on: .artist("a"))
        #expect(focus.nodeIDs.contains(.artist("a")))
        #expect(focus.nodeIDs.contains(.artist("b")))
        #expect(focus.nodeIDs.contains(.movement("m")))
        #expect(focus.nodeIDs.contains(.artwork("work-one")))
        #expect(!focus.nodeIDs.contains(.artist("c")))
        #expect(!focus.nodeIDs.contains(.artwork("work-two")))
        #expect(focus.artistRelationshipIDs == ["ab"])
        #expect(focus.edges.allSatisfy { $0.from == .artist("a") || $0.to == .artist("a") })
    }

    @Test func focusKindFilterKeepsMembershipAndDoesNotInventUnrecordedInfluence() throws {
        let snapshot = try load(artistEdges: [edge("influence", "a", "b", .influence), edge("meeting", "a", "c", .crossedPaths)])
        let focus = snapshot.focus(on: .artist("a"), relationshipKind: .influence)
        #expect(focus.artistRelationshipIDs == ["influence"])
        #expect(focus.nodeIDs.contains(.artwork("work-one")))
        #expect(!focus.nodeIDs.contains(.artist("c")))
        #expect(snapshot.focus(on: .artist("missing")) == .empty)
        #expect(snapshot.focus(on: .movement("missing")) == .empty)
    }

    @Test func coreCanvasAndArtistArtworkListsAreBoundedByCuratedMembership() throws {
        let snapshot = try load(artists: [artist("a")], annotations: [annotation("work-one", "a")])
        #expect(snapshot.artworks.map(\.id) == ["work-one"])
        #expect(snapshot.artworks(for: "a").map(\.id) == ["work-one"])
        #expect(snapshot.artwork(id: "work-two") != nil)
        #expect(snapshot.movements(for: "work-one").map(\.id) == ["m"])
    }

    @Test func fileLoadingReadsOfflineResourcesWithoutMutatingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MuseFrame-History-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json"), guidesURL = directory.appendingPathComponent("guides.json")
        let history = try historyData(), guides = try guideData([overlay()])
        try history.write(to: historyURL); try guides.write(to: guidesURL)
        let repository = ArtHistoryRepository(historyURL: historyURL, guidesURL: guidesURL)
        let snapshot = repository.load(artworks: works())
        #expect(snapshot.artists.count == 3)
        #expect(snapshot.guideOverlays.count == 1)
        #expect(try Data(contentsOf: historyURL) == history)
        #expect(try Data(contentsOf: guidesURL) == guides)
    }

    private var sources: [URL] { [URL(string: "https://www.metmuseum.org/art/collection/search/436535")!] }
    private func artist(_ id: String) -> Artist {
        Artist(id: id, nameOriginal: "Artist \(id.uppercased())", nameZh: "艺术家 \(id.uppercased())", birthYear: 1800, deathYear: 1900,
            movementIDs: ["m"], sourceRefs: sources, representativeArtworkIDs: [id == "a" ? "work-one" : id == "b" ? "work-two" : "work-three"])
    }
    private func movement() -> Movement {
        Movement(id: "m", nameOriginal: "Impressionism", nameZh: "印象派", startYear: 1860, endYear: 1900, sourceRefs: sources)
    }
    private func annotation(_ work: String, _ artist: String) -> ArtworkAnnotation {
        ArtworkAnnotation(artworkID: work, artistID: artist, movementIDs: ["m"])
    }
    private func edge(_ id: String, _ from: String, _ to: String, _ kind: ArtistRelationship.Kind = .influence) -> ArtistRelationship {
        ArtistRelationship(id: id, fromArtistID: from, toArtistID: to, kind: kind, evidenceSummaryZh: "Referenced test relation", sourceRefs: sources)
    }
    private func event(_ id: String, _ year: Int) -> TimelineEvent {
        TimelineEvent(id: id, year: year, titleOriginal: id, artistIDs: ["a"], sourceRefs: sources)
    }
    private func guide(summary: String = "Independent Chinese introduction") -> ArtworkGuide {
        ArtworkGuide(summary30s: summary, lookAtPoints: ["Observe the light", "Follow the horizon"], story: "Verified context",
            importance: "Independent analysis", sourceRefs: sources)
    }
    private func overlay() -> ArtworkGuideOverlay { ArtworkGuideOverlay(artworkID: "work-one", status: .published, guide: guide()) }
    private func guideData(_ guides: [ArtworkGuideOverlay]) throws -> Data {
        try JSONEncoder().encode(GuidePackage(guides: guides))
    }
    private func works() -> [Artwork] {
        ["one", "two", "three"].enumerated().map { index, id in
            let url = URL(string: "https://images.metmuseum.org/\(id).jpg")!
            return Artwork(id: "work-\(id)", source: .met, sourceID: id,
                titleOriginal: id == "one" ? "River in the Morning" : "Work \(id)", artistOriginal: "Artist \(["A", "B", "C"][index])",
                dateDisplay: "1889", yearStart: 1889, movement: "Impressionism", themes: ["风景"], museumName: "Museum", sourceURL: sources[0],
                image: ArtworkImage(originalURL: url, thumbnailURL: url, width: 4_000, height: 3_000, license: "CC0 1.0"),
                isPublicDomain: true, artistID: ["a", "b", "c"][index], yearEnd: 1889, metadataUpdatedAt: "2026-10-30")
        }
    }
    private func historyData(artists: [Artist]? = nil, movements: [Movement]? = nil, artistEdges: [ArtistRelationship] = [],
                             artworkEdges: [ArtworkRelationship] = [], annotations: [ArtworkAnnotation] = [], events: [TimelineEvent] = []) throws -> Data {
        try JSONEncoder().encode(HistoryPackage(artists: artists ?? [artist("a"), artist("b"), artist("c")],
            movements: movements ?? [movement()], artistRelationships: artistEdges, artworkRelationships: artworkEdges,
            timelineEvents: events, artworkAnnotations: annotations))
    }
    private func load(artists: [Artist]? = nil, movements: [Movement]? = nil, artistEdges: [ArtistRelationship] = [],
                      artworkEdges: [ArtworkRelationship] = [], annotations: [ArtworkAnnotation] = [], events: [TimelineEvent] = [],
                      guides: [ArtworkGuideOverlay] = [], catalog: [Artwork]? = nil, invalidated: Set<String> = []) throws -> ArtHistorySnapshot {
        ArtHistoryRepository.decode(historyData: try historyData(artists: artists, movements: movements, artistEdges: artistEdges,
            artworkEdges: artworkEdges, annotations: annotations, events: events), guideData: try guideData(guides),
            artworks: catalog ?? works(), invalidatedArtworkIDs: invalidated)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

private struct HistoryPackage: Encodable {
    var schemaVersion = 1
    var contentVersion = "test-v1"
    var artists: [Artist] = []
    var movements: [Movement] = []
    var artistRelationships: [ArtistRelationship] = []
    var artworkRelationships: [ArtworkRelationship] = []
    var timelineEvents: [TimelineEvent] = []
    var artworkAnnotations: [ArtworkAnnotation] = []
}
private struct GuidePackage: Encodable {
    let schemaVersion = 1
    let contentVersion = "test-v1"
    let guides: [ArtworkGuideOverlay]
}
