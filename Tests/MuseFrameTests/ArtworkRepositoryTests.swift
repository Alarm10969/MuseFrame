import Foundation
import Testing
@testable import MuseFrame

@Suite("Offline catalog and incremental museum synchronization")
struct ArtworkRepositoryTests {
    @Test func bundledCollectionContainsAtLeast300VerifiedOpenAccessWorks() async throws {
        let artworks = try await ArtworkRepository().loadSeed()
        #expect(artworks.count >= 300)
        #expect(Set(artworks.map(\.id)).count == artworks.count)
        #expect(artworks.allSatisfy { $0.isPublicDomain && $0.image.hasVerifiedResolution })
        #expect(artworks.allSatisfy { MuseFrameResources.bundle.url(forResource: $0.id, withExtension: "jpg") == nil })
        #expect(artworks.filter(\.hasPublishedGuide).count >= 5)
    }

    @Test func persistedMetadataIsReadyOfflineAndDeduplicatesStableIDs() async throws {
        let fixture = try CatalogFixture(seed: [catalogWork("1")])
        defer { fixture.remove() }
        let source = CatalogFixtureSource(search: [catalogWork("2")])
        let first = fixture.repository(sources: [source])
        try await first.persist([catalogWork("2"), catalogWork("2")])
        let reopened = fixture.repository(sources: [CatalogFixtureSource(failsSearch: true)])
        let result = try await reopened.loadCatalog()
        #expect(result.map(\.id) == ["met-1", "met-2"])
    }

    @Test func metadataRefreshRetainsCuratedLabelsGuidesAndVerifiedDimensions() throws {
        let old = catalogWork("1", curated: true)
        let refreshed = catalogWork("1", width: 0, title: "Updated museum title").preservingEditorialData(from: old)
        #expect(refreshed.titleOriginal == "Updated museum title")
        #expect(refreshed.titleZh == "策展中文标题")
        #expect(refreshed.movement == "Impressionism")
        #expect(refreshed.themes == ["风景"])
        #expect(refreshed.image.width == 4_000)
        #expect(refreshed.hasPublishedGuide)
        #expect(refreshed.dominantColors == ["暖色"])
    }

    @Test func replacementImageCannotReusePreviousPixelMeasurements() {
        let old = catalogWork("1", curated: true)
        let updated = catalogWork("1", width: 0, imageName: "replacement.jpg").preservingEditorialData(from: old)
        #expect(!updated.image.hasVerifiedResolution)
        #expect(updated.image.availableSizes == nil)
        #expect(updated.dominantColors.isEmpty)
        #expect(updated.hasPublishedGuide)
    }

    @Test func definitiveRightsInvalidationSurvivesRelaunchAndSeedMerge() async throws {
        let fixture = try CatalogFixture(seed: [catalogWork("1"), catalogWork("2")])
        defer { fixture.remove() }
        let source = CatalogFixtureSource(restrictedIDs: ["met-1"])
        let result = try await fixture.repository(sources: [source]).syncIfNeeded(force: true)
        #expect(result.invalidatedIDs == ["met-1"])
        #expect(result.artworks.map(\.id) == ["met-2"])
        let reopened = fixture.repository(sources: [source])
        #expect(try await reopened.loadCatalog().map(\.id) == ["met-2"])
        do {
            _ = try await reopened.artwork(id: "met-1")
            Issue.record("Invalidated art should not reappear through its deep link")
        } catch ArtworkSourceError.restrictedImage {}
    }

    @Test func transientMuseumFailureKeepsOfflineCollectionAndSuccessfulSourcePage() async throws {
        let fixture = try CatalogFixture(seed: [catalogWork("1")])
        defer { fixture.remove() }
        let met = CatalogFixtureSource(failsSearch: true, failsFetch: true)
        let aic = CatalogFixtureSource(source: .aic, search: [catalogWork("2", source: .aic)])
        let result = try await fixture.repository(sources: [met, aic]).syncIfNeeded(force: true)
        #expect(Set(result.artworks.map(\.id)) == ["met-1", "aic-2"])
        #expect(result.invalidatedIDs.isEmpty)
        #expect(!result.warnings.isEmpty)
    }

    @Test func discoveryCursorAndDailyTTLContinueAcrossRelaunch() async throws {
        let fixture = try CatalogFixture(seed: [catalogWork("1")])
        defer { fixture.remove() }
        let source = CatalogFixtureSource(search: [catalogWork("2")])
        _ = try await fixture.repository(sources: [source]).syncIfNeeded()
        let reopened = fixture.repository(sources: [source])
        _ = try await reopened.syncIfNeeded()
        #expect(await source.requestedPages == [1])
        _ = try await reopened.syncIfNeeded(force: true)
        #expect(await source.requestedPages == [1, 2])
    }

    @Test func damagedCatalogDoesNotPreventOfflineStartup() async throws {
        let fixture = try CatalogFixture(seed: [catalogWork("1")])
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("damaged cache".utf8).write(to: fixture.directory.appendingPathComponent("catalog-v1.json"))
        #expect(try await fixture.repository(sources: [CatalogFixtureSource()]).loadCatalog().count == 1)
    }

    @Test func legacySavedArtworkSnapshotDecodesWithoutNewOptionalFields() throws {
        let old = catalogWork("1")
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["artistID", "yearEnd", "metadataUpdatedAt"] { data.removeValue(forKey: key) }
        var image = try #require(data["image"] as? [String: Any])
        for key in ["detailURL", "bundledThumbnailSourceURL", "availableSizes", "subjectBounds", "safeCropRect", "focalPoint"] { image.removeValue(forKey: key) }
        data["image"] = image
        let restored = try JSONDecoder().decode(Artwork.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(restored.id == old.id)
        #expect(restored.artistID == nil)
        #expect(restored.image.detailURL == nil)
        #expect(restored.image.hasVerifiedResolution)
    }
}

private struct CatalogFixture {
    let root: URL
    let seedURL: URL
    let directory: URL

    init(seed: [Artwork]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MuseFrame-Catalog-\(UUID().uuidString)")
        directory = root.appendingPathComponent("Catalog")
        seedURL = root.appendingPathComponent("seed.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(seed).write(to: seedURL)
    }
    func repository(sources: [any ArtworkSourceProtocol]) -> ArtworkRepository {
        ArtworkRepository(sources: sources, directory: directory, seedURL: seedURL,
                          now: { Date(timeIntervalSince1970: 1_792_537_200) })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor CatalogFixtureSource: ArtworkSourceProtocol {
    nonisolated let source: ArtworkSource
    let searchResult: [Artwork]
    let restrictedIDs: Set<String>
    let failsSearch: Bool
    let failsFetch: Bool
    var requestedPages: [Int] = []

    init(source: ArtworkSource = .met, search: [Artwork] = [], restrictedIDs: Set<String> = [],
         failsSearch: Bool = false, failsFetch: Bool = false) {
        self.source = source
        searchResult = search
        self.restrictedIDs = restrictedIDs
        self.failsSearch = failsSearch
        self.failsFetch = failsFetch
    }
    func search(query: String, page: Int, pageSize: Int) async throws -> [Artwork] {
        requestedPages.append(page)
        if failsSearch { throw URLError(.notConnectedToInternet) }
        return searchResult
    }
    func fetchArtwork(id: String) async throws -> Artwork {
        if restrictedIDs.contains(id) { throw ArtworkSourceError.restrictedImage }
        if failsFetch { throw URLError(.timedOut) }
        return catalogWork(id.replacingOccurrences(of: source.rawValue + "-", with: ""), source: source)
    }
    func fetchImageCandidates(for artwork: Artwork) async throws -> [URL] { [artwork.image.originalURL] }
    nonisolated func licensePolicy(for artwork: Artwork) -> Bool { artwork.source == source && artwork.isPublicDomain }
}

private func catalogWork(_ id: String, source: ArtworkSource = .met, width: Int = 4_000,
                         title: String = "Museum title", imageName: String = "original.jpg", curated: Bool = false) -> Artwork {
    let original = URL(string: "https://images.metmuseum.org/\(id)/\(imageName)")!
    return Artwork(id: "\(source.rawValue)-\(id)", source: source, sourceID: id, titleOriginal: title,
        titleZh: curated ? "策展中文标题" : nil, artistOriginal: "Artist", dateDisplay: "1900",
        movement: curated ? "Impressionism" : "Other", themes: curated ? ["风景"] : [],
        museumName: source.displayName, sourceURL: URL(string: "https://www.metmuseum.org/art/collection/search/\(id)")!,
        image: ArtworkImage(originalURL: original, thumbnailURL: URL(string: "https://images.metmuseum.org/\(id)/small.jpg")!,
                            width: width, height: width > 0 ? 3_000 : 0, license: "CC0 1.0"), isPublicDomain: true,
        guideStatus: curated ? .published : .missing, dominantColors: curated ? ["暖色"] : [],
        guide: curated ? ArtworkGuide(summary30s: "独立中文导览", lookAtPoints: [], sourceRefs: []) : nil)
}
