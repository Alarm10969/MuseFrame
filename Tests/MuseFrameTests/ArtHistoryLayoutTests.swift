import Foundation
import Testing
@testable import MuseFrame

@Suite("Art history canvas behavior")
struct ArtHistoryLayoutTests {
    @Test func timelinePositionsKeepTrueYearDistancesWhenCollisionRowsAreAdded() throws {
        let snapshot = try fixture()
        let layout = HistoryCanvasLayout.make(snapshot: snapshot, mode: .timeline,
            viewport: CGSize(width: 1180, height: 680), movementID: "m", focus: .movement("m"))
        let first = try #require(layout.node(.artwork("work-0")))
        let second = try #require(layout.node(.artwork("work-1")))
        let third = try #require(layout.node(.artwork("work-2")))
        #expect(first.center.x < second.center.x)
        #expect(second.center.x < third.center.x)
        #expect(abs((third.center.x - first.center.x) - 2 * (second.center.x - first.center.x)) < 0.001)
        #expect(first.center.y != second.center.y)
        #expect(layout.lifeSpans.count == 6)
        let movement = try #require(layout.node(.movement("m")))
        // The period midpoint is 1865, between the 1860 and 1870 artwork positions.
        #expect(movement.center.x > second.center.x)
        #expect(movement.center.x < third.center.x)
    }

    @Test func focusCanRevealAnArtistAndArtworkOutsideTheSparseDefaultSelection() throws {
        let snapshot = try fixture()
        let viewport = CGSize(width: 1180, height: 680)
        let initial = HistoryCanvasLayout.make(snapshot: snapshot, mode: .graph, viewport: viewport)
        #expect(initial.node(.artist("artist-7")) == nil)
        #expect(initial.node(.artwork("work-7")) == nil)
        let focused = HistoryCanvasLayout.make(snapshot: snapshot, mode: .graph, viewport: viewport, focus: .artwork("work-7"))
        #expect(focused.node(.artist("artist-7")) != nil)
        #expect(focused.node(.artwork("work-7")) != nil)
    }

    @Test func movementFocusKeepsTheOverviewBoundedWhileAnExplicitFilterAddsOnlyACuratedSubset() throws {
        let snapshot = try fixture()
        let viewport = CGSize(width: 1180, height: 680)
        let overview = HistoryCanvasLayout.make(snapshot: snapshot, mode: .graph, viewport: viewport, focus: .movement("m"))
        let filtered = HistoryCanvasLayout.make(snapshot: snapshot, mode: .graph, viewport: viewport, movementID: "m", focus: .movement("m"))
        #expect(overview.nodes.filter { if case .artist = $0.id { true } else { false } }.count == 2)
        #expect(overview.nodes.filter { if case .artwork = $0.id { true } else { false } }.count == 2)
        #expect(filtered.nodes.filter { if case .artist = $0.id { true } else { false } }.count == 6)
        #expect(filtered.nodes.filter { if case .artwork = $0.id { true } else { false } }.count <= 8)
    }

    @Test func layoutIsStableBoundedAndHasOnePositionPerNodeAcrossWindowSizes() throws {
        let snapshot = try fixture()
        for width in [1180.0, 1440, 1920] {
            for mode in HistoryCanvasMode.allCases {
                let viewport = CGSize(width: width, height: 680)
                let first = HistoryCanvasLayout.make(snapshot: snapshot, mode: mode, viewport: viewport, focus: .movement("m"))
                let second = HistoryCanvasLayout.make(snapshot: snapshot, mode: mode, viewport: viewport, focus: .movement("m"))
                #expect(first == second)
                #expect(Set(first.nodes.map(\.id)).count == first.nodes.count)
                #expect(first.nodes.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite })
                #expect(first.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.minY >= 0 })
                #expect(first.nodes.allSatisfy { $0.frame.maxX <= first.size.width && $0.frame.maxY <= first.size.height })
            }
        }
    }

    @Test func movementAndArtistFiltersDoNotLeakOtherArtistsIntoTheCanvas() throws {
        let snapshot = try fixture()
        let layout = HistoryCanvasLayout.make(snapshot: snapshot, mode: .graph,
            viewport: CGSize(width: 1180, height: 680), movementID: "m", artistID: "artist-5", focus: .artist("artist-5"))
        #expect(layout.node(.artist("artist-5")) != nil)
        #expect(layout.node(.artwork("work-5")) != nil)
        #expect(layout.nodes.filter { if case .artist = $0.id { true } else { false } }.count == 1)
        #expect(layout.nodes.filter { if case .artwork = $0.id { true } else { false } }.count == 1)
    }

    private func fixture() throws -> ArtHistorySnapshot {
        let source = URL(string: "https://www.metmuseum.org/art/collection/search/436535")!
        let image = ArtworkImage(originalURL: source, thumbnailURL: source, width: 4000, height: 3000, license: "CC0 1.0")
        let artworks = (0..<8).map { index in
            Artwork(id: "work-\(index)", source: .met, sourceID: "\(index)", titleOriginal: "Work \(index)",
                artistOriginal: "Artist \(index)", dateDisplay: "\(1850 + index * 10)", yearStart: 1850 + index * 10,
                movement: "Fixture", museumName: "Fixture", sourceURL: source, image: image, isPublicDomain: true,
                artistID: "artist-\(index)")
        }
        let artists = (0..<8).map { index in
            Artist(id: "artist-\(index)", nameOriginal: "Artist \(index)", birthYear: 1800 + index * 10,
                deathYear: 1870 + index * 10, movementIDs: ["m"], sourceRefs: [source], representativeArtworkIDs: ["work-\(index)"])
        }
        let movement = Movement(id: "m", nameOriginal: "Fixture", startYear: 1780, endYear: 1950, sourceRefs: [source])
        let annotations = (0..<8).map { ArtworkAnnotation(artworkID: "work-\($0)", artistID: "artist-\($0)", movementIDs: ["m"]) }
        let data = try JSONEncoder().encode(LayoutPackage(artists: artists, movements: [movement], artworkAnnotations: annotations))
        let guides = Data(#"{"schemaVersion":1,"contentVersion":"test","guides":[]}"#.utf8)
        return ArtHistoryRepository.decode(historyData: data, guideData: guides, artworks: artworks)
    }
}

private struct LayoutPackage: Encodable {
    let schemaVersion = 1
    let contentVersion = "test"
    let artists: [Artist]
    let movements: [Movement]
    let artworkAnnotations: [ArtworkAnnotation]
}
