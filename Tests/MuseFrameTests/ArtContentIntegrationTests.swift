import Foundation
import Testing
@testable import MuseFrame

@Suite("Bundled art experience edition")
struct ArtContentIntegrationTests {
    @Test func publishedEditionLoadsOfflineWithoutDiscardingContentOrChangingMuseumRecords() async throws {
        let seed = try await ArtworkRepository().loadSeed()
        let snapshot = ArtHistoryRepository().load(artworks: seed)
        #expect(snapshot.diagnostics.isEmpty, "Bundled content must not depend on silent repairs: \(snapshot.diagnostics)")
        #expect((80...100).contains(snapshot.guideOverlays.count))
        #expect(Set(snapshot.guideOverlays.keys) == snapshot.coreArtworkIDs)
        #expect(snapshot.artworks.count == snapshot.coreArtworkIDs.count)
        let enriched = seed.map { snapshot.applyingEditorialOverlay(to: $0) }
        #expect(enriched.count == seed.count)
        for (original, current) in zip(seed, enriched) {
            #expect(original.id == current.id && original.artistID == current.artistID)
            #expect(original.sourceURL == current.sourceURL && original.image == current.image)
            #expect(original.titleOriginal == current.titleOriginal && original.artistOriginal == current.artistOriginal)
            #expect(original.yearStart == current.yearStart && original.yearEnd == current.yearEnd)
            #expect(original.movement == current.movement && original.isPublicDomain == current.isPublicDomain)
            if snapshot.coreArtworkIDs.contains(current.id) {
                let guide = try #require(current.guide)
                #expect(current.hasPublishedGuide)
                #expect(guide.lookAtPoints.count >= 2 && guide.sourceRefs.contains(current.sourceURL))
                #expect(!guide.summary30s.isEmpty && guide.story?.isEmpty == false && guide.importance?.isEmpty == false)
            }
        }
    }

    @Test func everyCoreWorkCanBeLocatedAndExploredThroughValidatedMembership() async throws {
        let seed = try await ArtworkRepository().loadSeed()
        let snapshot = ArtHistoryRepository().load(artworks: seed)
        let artistIDs = Set(snapshot.artists.map(\.id))
        let movementIDs = Set(snapshot.movements.map(\.id))
        for artwork in snapshot.artworks {
            let artist = try #require(snapshot.artist(for: artwork.id))
            #expect(artistIDs.contains(artist.id))
            #expect(snapshot.search(query: artwork.titleOriginal, limit: 100).contains { $0.target == .artwork(artwork.id) })
            let movements = snapshot.movements(for: artwork.id)
            #expect(!movements.isEmpty && movements.allSatisfy { movementIDs.contains($0.id) })
            let focus = snapshot.focus(on: .artwork(artwork.id))
            #expect(focus.nodeIDs.contains(.artist(artist.id)))
            #expect(movements.allSatisfy { focus.nodeIDs.contains(.movement($0.id)) })
            for mode in HistoryCanvasMode.allCases {
                let layout = HistoryCanvasLayout.make(snapshot: snapshot, mode: mode,
                    viewport: CGSize(width: 1180, height: 680), focus: .artwork(artwork.id))
                #expect(layout.node(.artwork(artwork.id)) != nil)
                #expect(layout.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.minY >= 0 && $0.frame.maxX <= layout.size.width && $0.frame.maxY <= layout.size.height })
            }
        }
        let supportedKinds = Set(snapshot.artistRelationships.map(\.kind))
        #expect(supportedKinds.contains(.influence) && supportedKinds.contains(.teacherStudent))
        #expect(!snapshot.artworkRelationships.isEmpty)
        #expect(snapshot.timelineEvents.map(\.year) == snapshot.timelineEvents.map(\.year).sorted())
    }
}
