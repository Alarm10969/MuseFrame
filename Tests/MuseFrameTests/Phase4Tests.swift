import Foundation
import Testing
@testable import MuseFrame

@Suite("Phase 4 curated content and display recovery")
struct Phase4Tests {
    @Test func dahlEditionIsCompleteSearchableAndUsesVerifiedImages() async throws {
        let seed = try await ArtworkRepository().loadSeed()
        let snapshot = ArtHistoryRepository().load(artworks: seed)
        #expect(snapshot.diagnostics.isEmpty)
        let artist = try #require(snapshot.artist(id: "met-artist-161802"))
        let works = snapshot.artworks(for: artist.id)
        #expect(Set(works.map(\.id)) == ["commons-dresden-1839", "met-439343", "met-439344", "met-438159", "met-438954"])
        #expect(snapshot.search(query: "约翰克里斯蒂安达尔").contains { $0.target == .artist(artist.id) })
        for work in works {
            #expect(work.hasPublishedGuide && work.image.hasVerifiedResolution)
            #expect(snapshot.movements(for: work.id).contains { $0.id == "romanticism" })
            #expect(work.image.thumbnailURL.scheme == "https")
            #expect(MuseFrameResources.bundle.url(forResource: work.id, withExtension: "jpg") == nil)
        }
        let dresden = try #require(works.first { $0.id == CuratedCommonsSource.dresdenID })
        #expect(dresden.yearStart == 1839 && dresden.image.width == 4984 && dresden.image.height == 2957)
        #expect(dresden.source == .commons && dresden.museumName.contains("Dresden"))
    }

    @Test func curatedSourceDoesNotAdmitArbitraryCommonsImagesOrRestrictedRecords() async throws {
        let source = CuratedCommonsSource()
        let work = try await source.fetchArtwork(id: CuratedCommonsSource.dresdenID)
        #expect(source.licensePolicy(for: work))
        let data = try JSONEncoder().encode(work)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for mutation in ["id", "url", "license", "rights"] {
            var json = original
            var image = try #require(json["image"] as? [String: Any])
            switch mutation {
            case "id": json["id"] = "commons-unreviewed"
            case "url": image["originalURL"] = "https://upload.wikimedia.org/wikipedia/commons/unreviewed.jpg"
            case "license": image["license"] = "All rights reserved"
            default: json["isPublicDomain"] = false
            }
            json["image"] = image
            let changed = try JSONDecoder().decode(Artwork.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(!source.licensePolicy(for: changed))
        }
        #expect(try await source.search(query: "德累斯顿", page: 1, pageSize: 20).map(\.id) == [work.id])
        #expect(try await source.search(query: "painting", page: 2, pageSize: 20).isEmpty)
        await #expect(throws: ArtworkSourceError.self) { try await source.fetchArtwork(id: "commons-unreviewed") }
    }

    @Test func curatedCatalogSurvivesOfflineReopenWithoutDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CuratedCommonsSource()
        let repository = ArtworkRepository(sources: [source], directory: root)
        let work = try await source.fetchArtwork(id: CuratedCommonsSource.dresdenID)
        try await repository.persist([work, work])
        _ = try await repository.syncIfNeeded(force: true)
        let restored = try await ArtworkRepository(sources: [source], directory: root).loadCatalog()
        #expect(restored.map(\.id) == [work.id])
        #expect(restored.first?.image.originalURL == work.image.originalURL)
    }

    @Test func displayDisconnectDuringRenderPreventsAnyCommit() {
        #expect(throws: WallpaperError.self) {
            try WallpaperDisplayValidation.validate(prepared: [display("main"), display("external")], connected: [display("main")])
        }
        #expect(throws: WallpaperError.self) {
            try WallpaperDisplayValidation.validate(prepared: [], connected: [display("main")])
        }
    }

    @Test func wakeResolutionChangeRejectsStaleCropButReorderedDisplaysRemainValid() throws {
        #expect(throws: WallpaperError.self) {
            try WallpaperDisplayValidation.validate(prepared: [display("main")], connected: [display("main", width: 1920)])
        }
        try WallpaperDisplayValidation.validate(prepared: [display("main"), display("external")],
            connected: [display("external"), display("main"), display("new")])
    }

    private func display(_ id: String, width: Int = 3840) -> ScreenProfile {
        ScreenProfile(id: id, name: id, logicalWidth: Double(width) / 2, logicalHeight: 1080,
                      pixelWidth: width, pixelHeight: 2160, scale: 2, isMain: id == "main")
    }
}
