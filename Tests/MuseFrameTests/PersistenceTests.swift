import Foundation
import SwiftData
import Testing
@testable import MuseFrame

@Suite("Saved artwork persistence")
struct PersistenceTests {
    @Test @MainActor func savedMetadataSurvivesContextReloadAndCanBeRemoved() throws {
        let container = try ModelContainer(for: SavedArtwork.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let write = ModelContext(container)
        let artwork = GalleryFilterTests().artwork()
        write.insert(try SavedArtwork(artwork: artwork))
        try write.save()
        let read = ModelContext(container)
        let saved = try read.fetch(FetchDescriptor<SavedArtwork>())
        #expect(saved.count == 1)
        #expect(saved.first?.artworkID == artwork.id)
        let decoded = try JSONDecoder().decode(Artwork.self, from: #require(saved.first?.snapshot))
        #expect(decoded.displayTitle == "河畔落日")
        read.delete(try #require(saved.first))
        try read.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<SavedArtwork>()) == 0)
    }
}
