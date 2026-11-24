import Foundation
import SwiftData
import Testing
@testable import MuseFrame

@Suite("Gallery, Saved, Widget and rotation state integration")
struct AppModelIntegrationTests {
    @Test @MainActor func detailAndHistoryRoutesShareTheSameSelectionWithoutChangingGalleryFilters() async throws {
        let work = integrationArtwork("history", artist: "Fixture Artist")
        let outside = integrationArtwork("outside", artist: "Another Artist")
        let fixture = try AppIntegrationFixture(artworks: [work, outside])
        defer { fixture.remove() }
        let historyURL = fixture.root.appendingPathComponent("history.json")
        let guidesURL = fixture.root.appendingPathComponent("guides.json")
        let source = work.sourceURL.absoluteString
        let document: [String: Any] = [
            "schemaVersion": 1, "contentVersion": "test",
            "artists": [["id": "fixture-artist", "nameOriginal": "Fixture Artist", "nameZh": "测试画家",
                          "movementIDs": ["fixture-movement"], "representativeArtworkIDs": [work.id], "sourceRefs": [source]]],
            "movements": [["id": "fixture-movement", "nameOriginal": "Fixture Movement", "nameZh": "测试流派",
                            "startYear": 1800, "endYear": 1950, "sourceRefs": [source]]],
            "artworkAnnotations": [["artworkID": work.id, "artistID": "fixture-artist", "movementIDs": ["fixture-movement"]]],
            "artistRelationships": [], "artworkRelationships": [], "timelineEvents": []
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: historyURL)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "contentVersion": "test", "guides": []]).write(to: guidesURL)
        let history = ArtHistoryRepository(historyURL: historyURL, guidesURL: guidesURL)
        let model = fixture.model(historyRepository: history)
        await model.start(synchronize: false, scheduleRotation: false)
        model.filter.query = "preserve this search"
        let originalFilter = model.filter
        await model.openArtwork(id: work.id)
        #expect(model.selectedArtwork?.id == work.id)
        #expect(model.focusHistory(.artist("fixture-artist")))
        #expect(model.tab == .history && model.selectedArtwork == nil)
        #expect(model.historyFocus == .artist("fixture-artist"))
        await model.navigate(to: .movement("fixture-movement"))
        #expect(model.historyFocus == .movement("fixture-movement"))
        #expect(model.filter == originalFilter)
        await model.navigate(to: .artist("fixture-artist"))
        #expect(model.historyFocus == .artist("fixture-artist"))
        #expect(model.focusHistory(.artwork(work.id)))
        #expect(!model.focusHistory(.artwork(outside.id)))
        await model.openArtwork(id: work.id)
        #expect(model.tab == .history && model.selectedArtwork?.id == work.id)
        await model.navigate(to: .artist("unknown-artist"))
        #expect(model.tab == .history && model.historyFocus == nil && model.selectedArtwork == nil)
        #expect(model.filter == originalFilter)
    }

    @Test @MainActor func rotationConfigurationHintsAfterCommitOnlyWhenSettingsActuallyChange() async throws {
        let fixture = try AppIntegrationFixture(artworks: [integrationArtwork("7")])
        defer { fixture.remove() }
        var observedEnabled: [Bool] = []
        let current = CurrentArtworkStore(directory: fixture.currentDirectory, reloadTimelines: {
            let archive = try? RotationSharedStore(storageURL: fixture.rotationURL).load()
            observedEnabled.append(archive?.settings.enabled == true)
        }, widgetReloadInterval: 0)
        let model = fixture.model(currentStore: current)
        await model.start(synchronize: false, scheduleRotation: false)
        model.updateRotation { $0.enabled = true; $0.cadence = .hourly }
        #expect(observedEnabled == [true])
        #expect(try RotationSharedStore(storageURL: fixture.rotationURL).load().state.nextDueDate != nil)
        model.updateRotation { $0.enabled = true }
        #expect(observedEnabled == [true])
        model.updateRotation { $0.enabled = false }
        #expect(observedEnabled == [true, false])
        #expect(CurrentArtworkStorage.load(directory: fixture.currentDirectory) == nil)

        // A failed settings transaction must not advertise a schedule that was never saved.
        try FileManager.default.removeItem(at: fixture.rotationURL)
        try FileManager.default.createDirectory(at: fixture.rotationURL, withIntermediateDirectories: true)
        model.updateRotation { $0.enabled = true }
        #expect(observedEnabled == [true, false])
        #expect(model.notice != nil)
    }

    @Test @MainActor func unknownOrWithdrawnDeepLinkReturnsToGalleryAndClosesPreviousDetail() async throws {
        let work = integrationArtwork("7")
        let fixture = try AppIntegrationFixture(artworks: [work])
        defer { fixture.remove() }
        let model = fixture.model()
        await model.start(synchronize: false, scheduleRotation: false)
        model.tab = .saved
        model.selectedArtwork = work
        await model.openArtwork(id: "met-missing")
        #expect(model.tab == .gallery)
        #expect(model.selectedArtwork == nil)
        #expect(model.notice != nil)
    }
    @Test @MainActor func concurrentStartupWaitsForTheSameCatalogAndExportsOnlyValidatedWorks() async throws {
        let work = integrationArtwork("7")
        let fixture = try AppIntegrationFixture(artworks: [work])
        defer { fixture.remove() }
        let model = fixture.model()
        async let first: Void = model.start(synchronize: false, scheduleRotation: false)
        async let second: Void = model.start(synchronize: false, scheduleRotation: false)
        _ = await (first, second)
        #expect(model.artworks.map(\.id) == [work.id])
        let projection = try RotationSharedStore(storageURL: fixture.rotationURL).loadLibrary()
        #expect(projection?.artworks.map(\.id) == [work.id])
        #expect(model.rotation.library?.savedIDs.isEmpty == true)
        model.toggleSaved(work)
        #expect(try RotationSharedStore(storageURL: fixture.rotationURL).loadLibrary()?.savedIDs == [work.id])
        model.toggleSaved(work)
        #expect(try RotationSharedStore(storageURL: fixture.rotationURL).loadLibrary()?.savedIDs.isEmpty == true)
        #expect(await fixture.source.searchCalls == 0)
    }

    @Test @MainActor func savedStateIsConsistentAcrossGalleryDetailCurrentSnapshotAndContextReload() async throws {
        let work = integrationArtwork("1")
        let fixture = try AppIntegrationFixture(artworks: [work])
        defer { fixture.remove() }
        let current = fixture.currentStore()
        current.update(work)
        let model = fixture.model(currentStore: current)
        await model.start(synchronize: false, scheduleRotation: false)
        await model.openArtwork(id: work.id)
        #expect(model.selectedArtwork?.id == work.id)
        model.toggleSaved(work)
        #expect(model.isSaved(work))
        #expect(model.selectedArtwork.map(model.isSaved) == true)
        #expect(current.snapshot?.isSaved == true)
        #expect(CurrentArtworkStorage.load(directory: fixture.currentDirectory)?.isSaved == true)
        model.tab = .saved
        #expect(model.visibleArtworks.map(\.id) == [work.id])
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<SavedArtwork>()) == 1)

        // A new AppModel and ModelContext share the same isolated SwiftData store.
        let reopenedCurrent = fixture.currentStore()
        let reopened = fixture.model(currentStore: reopenedCurrent)
        await reopened.start(synchronize: false, scheduleRotation: false)
        #expect(reopened.isSaved(work))
        #expect(reopenedCurrent.snapshot?.isSaved == true)
        reopened.toggleSaved(work)
        #expect(!reopened.isSaved(work))
        #expect(reopenedCurrent.snapshot?.isSaved == false)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<SavedArtwork>()) == 0)
    }

    @Test @MainActor func capturedRotationFilterRemainsIndependentOfLaterGalleryBrowsingAndRestarts() async throws {
        let matching = integrationArtwork("1", artist: "Monet", movement: "Impressionism", themes: ["风景"])
        let other = integrationArtwork("2", artist: "Rembrandt", movement: "Baroque", themes: ["人物"])
        let fixture = try AppIntegrationFixture(artworks: [matching, other])
        defer { fixture.remove() }
        let model = fixture.model()
        await model.start(synchronize: false, scheduleRotation: false)
        model.filter.artist = "Monet"
        model.filter.movement = "Impressionism"
        model.filter.theme = "风景"
        model.captureRotationFilters()
        let snapshot = model.rotation.settings
        model.filter.artist = "Rembrandt"
        model.filter.movement = "Baroque"
        model.filter.theme = "人物"
        #expect(model.rotation.settings.filter == snapshot.filter)
        #expect(model.rotationCandidates(snapshot).map(\.id) == [matching.id])
        let reopened = fixture.model()
        await reopened.start(synchronize: false, scheduleRotation: false)
        #expect(reopened.rotation.settings.filter == snapshot.filter)
        #expect(reopened.rotationCandidates(reopened.rotation.settings).map(\.id) == [matching.id])
    }

    @Test @MainActor func widgetDeepLinkRestoresMissingCatalogWorkLocallyAndSavingShowsItImmediately() async throws {
        let seed = integrationArtwork("1")
        let external = integrationArtwork("99", artist: "Current artwork artist")
        let fixture = try AppIntegrationFixture(artworks: [seed])
        defer { fixture.remove() }
        let current = fixture.currentStore()
        current.update(external)
        let model = fixture.model(currentStore: current)
        await model.start(synchronize: false, scheduleRotation: false)
        await model.openArtwork(id: external.id)
        #expect(model.selectedArtwork?.id == external.id)
        #expect(await fixture.source.fetchCalls == 0)
        #expect(await fixture.source.searchCalls == 0)
        model.toggleSaved(external)
        model.tab = .saved
        #expect(model.visibleArtworks.map(\.id) == [external.id])
        #expect(current.snapshot?.isSaved == true)
    }

    @Test @MainActor func startIsIdempotentAndDoesNotDuplicateSeedSavedOrRotationRuntime() async throws {
        let work = integrationArtwork("1")
        let fixture = try AppIntegrationFixture(artworks: [work, work])
        defer { fixture.remove() }
        let model = fixture.model()
        model.toggleSaved(work)
        await model.start(synchronize: false, scheduleRotation: false)
        await model.start(synchronize: false, scheduleRotation: false)
        #expect(model.artworks.map(\.id) == [work.id])
        #expect(model.rotation.isRunning)
        #expect(await fixture.source.fetchCalls == 0)
        #expect(await fixture.source.searchCalls == 0)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<SavedArtwork>()) == 1)
    }

    @Test @MainActor func savedSnapshotCannotReintroduceTombstonedWorkBeforeBackgroundSynchronization() async throws {
        let denied = integrationArtwork("1")
        let allowed = integrationArtwork("2")
        let fixture = try AppIntegrationFixture(artworks: [denied, allowed], restrictedIDs: [denied.id])
        defer { fixture.remove() }
        let context = ModelContext(fixture.container)
        context.insert(try SavedArtwork(artwork: denied))
        try context.save()
        let invalidation = try await fixture.repository().syncIfNeeded(force: true)
        #expect(invalidation.invalidatedIDs.contains(denied.id))
        let model = fixture.model()
        await model.start(synchronize: false, scheduleRotation: false)
        #expect(!model.artworks.contains { $0.id == denied.id })
        model.tab = .saved
        #expect(model.visibleArtworks.isEmpty)
        var settings = RotationSettings()
        settings.pool = .all
        #expect(!model.rotationCandidates(settings).contains { $0.id == denied.id })
        // User history is retained; invalidation removes browse/rotation eligibility, not personal state.
        #expect(model.isSaved(denied))
    }
}

@MainActor
private struct AppIntegrationFixture {
    let root: URL
    let catalogDirectory: URL
    let seedURL: URL
    let currentDirectory: URL
    let rotationURL: URL
    let container: ModelContainer
    let source: IntegrationMuseumSource

    init(artworks: [Artwork], restrictedIDs: Set<String> = []) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MuseFrame-AppIntegration-\(UUID().uuidString)")
        catalogDirectory = root.appendingPathComponent("Catalog")
        seedURL = root.appendingPathComponent("seed.json")
        currentDirectory = root.appendingPathComponent("Current")
        rotationURL = root.appendingPathComponent("rotation.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(artworks).write(to: seedURL)
        container = try ModelContainer(for: SavedArtwork.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        source = IntegrationMuseumSource(artworks: artworks, restrictedIDs: restrictedIDs)
    }
    func repository() -> ArtworkRepository {
        ArtworkRepository(sources: [source], directory: catalogDirectory, seedURL: seedURL)
    }
    func currentStore() -> CurrentArtworkStore { CurrentArtworkStore(directory: currentDirectory, reloadTimelines: {}) }
    func model(currentStore: CurrentArtworkStore? = nil,
               historyRepository: ArtHistoryRepository = ArtHistoryRepository()) -> AppModel {
        AppModel(repository: repository(), modelContainer: container,
                 rotation: RotationEngine(storageURL: rotationURL),
                 currentStore: currentStore ?? self.currentStore(), autoStart: false, historyRepository: historyRepository)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor IntegrationMuseumSource: ArtworkSourceProtocol {
    nonisolated let source = ArtworkSource.met
    let artworks: [String: Artwork]
    let restrictedIDs: Set<String>
    var fetchCalls = 0
    var searchCalls = 0

    init(artworks: [Artwork], restrictedIDs: Set<String>) {
        self.artworks = Dictionary(artworks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.restrictedIDs = restrictedIDs
    }
    func search(query: String, page: Int, pageSize: Int) async throws -> [Artwork] { searchCalls += 1; return [] }
    func fetchArtwork(id: String) async throws -> Artwork {
        fetchCalls += 1
        if restrictedIDs.contains(id) { throw ArtworkSourceError.restrictedImage }
        guard let artwork = artworks[id] else { throw ArtworkSourceError.httpStatus(404) }
        return artwork
    }
    func fetchImageCandidates(for artwork: Artwork) async throws -> [URL] { [artwork.image.originalURL] }
    nonisolated func licensePolicy(for artwork: Artwork) -> Bool { artwork.isPublicDomain && artwork.source == source }
}

private func integrationArtwork(_ id: String, artist: String = "Artist", movement: String = "Other", themes: [String] = []) -> Artwork {
    Artwork(id: "met-\(id)", source: .met, sourceID: id, titleOriginal: "Artwork \(id)", artistOriginal: artist,
            dateDisplay: "1900", movement: movement, themes: themes, museumName: "Fixture Museum",
            sourceURL: URL(string: "https://www.metmuseum.org/art/collection/search/\(id)")!,
            image: ArtworkImage(originalURL: URL(string: "https://images.metmuseum.org/\(id)/original.jpg")!,
                                thumbnailURL: URL(string: "https://images.metmuseum.org/\(id)/small.jpg")!,
                                width: 4_000, height: 3_000, license: "CC0 1.0"), isPublicDomain: true)
}

extension AppModelIntegrationTests {
    @Test @MainActor func onlineEditionUpdatesGalleryAndGuideTogetherAndReopensOffline() async throws {
        let seed = try await ArtworkRepository().loadSeed()
        let fixture = try AppIntegrationFixture(artworks: seed)
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("edition.json")
        func resource(_ name: String) throws -> [String: Any] {
            let url = try #require(MuseFrameResources.bundle.url(forResource: name, withExtension: "json"))
            return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }
        let history = try resource("art_history_curated")
        var guides = try resource("artwork_guides_zh")
        var rows = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [[String: Any]])
        var extra = rows[0]
        extra["id"] = "met-99999999"
        extra["sourceID"] = "99999999"
        extra["titleOriginal"] = "Test addition"
        rows.insert(extra, at: 0)
        var entries = try #require(guides["guides"] as? [[String: Any]])
        let guideID = try #require(entries[0]["artworkID"] as? String)
        var guide = try #require(entries[0]["guide"] as? [String: Any])
        guide["summary30s"] = "独立发布的新版导览。"
        entries[0]["guide"] = guide
        guides["guides"] = entries
        let payload: [String: Any] = ["schemaVersion": 1, "revision": 2, "artworks": rows, "guides": guides, "history": history]
        try JSONSerialization.data(withJSONObject: payload).write(to: file, options: .atomic)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.currentDirectoryURL = fixture.root
        server.arguments = ["-u", "-c", """
        from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
        server = ThreadingHTTPServer(('127.0.0.1', 0), SimpleHTTPRequestHandler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """]
        let output = Pipe()
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let address = try #require(URL(string: "http://127.0.0.1:\(port)/edition.json"))
        func model() -> AppModel {
            AppModel(repository: fixture.repository(), modelContainer: fixture.container,
                rotation: RotationEngine(storageURL: fixture.rotationURL), currentStore: fixture.currentStore(), autoStart: false,
                editorialStore: EditorialStore(directory: fixture.root.appendingPathComponent("Editions")), feedAddress: { address })
        }
        let app = model()
        await app.start(synchronize: false, scheduleRotation: false)
        #expect(!app.artworks.contains { $0.id == "met-99999999" })
        await app.synchronizeCatalog(force: true)
        #expect(app.artworks.first?.id == "met-99999999")
        #expect(app.artworks.first(where: { $0.id == guideID })?.guide?.summary30s == "独立发布的新版导览。")
        var invalid = payload
        invalid["history"] = ["schemaVersion": 99]
        try JSONSerialization.data(withJSONObject: invalid).write(to: file, options: .atomic)
        await app.synchronizeCatalog(force: true)
        #expect(app.artworks.first?.id == "met-99999999")
        server.terminate()
        server.waitUntilExit()
        let offline = model()
        await offline.start(synchronize: false, scheduleRotation: false)
        #expect(offline.artworks.first?.id == "met-99999999")
        #expect(offline.artworks.first(where: { $0.id == guideID })?.guide?.summary30s == "独立发布的新版导览。")
    }
}
