import Foundation
import Testing
@testable import MuseFrame

@Suite("Museum metadata and licenses")
struct ProviderTests {
    @Test func metNormalizesStableIdentityWithoutInventingResolution() throws {
        let object = try JSONDecoder().decode(MetObject.self, from: Data("""
        {"objectID":436535,"isPublicDomain":true,"primaryImage":"https://images.metmuseum.org/CRDImages/ep/original/test.jpg",
         "primaryImageSmall":"https://images.metmuseum.org/CRDImages/ep/web-large/test.jpg",
         "title":" Wheat Field with Cypresses ","artistDisplayName":"Vincent van Gogh","objectDate":"1889",
         "objectBeginDate":1889,"tags":[{"term":"Cypresses"}]}
        """.utf8))
        let source = MetMuseumSource()
        let artwork = try source.normalizeMetadata(object)
        #expect(artwork.id == "met-436535")
        #expect(artwork.titleOriginal == "Wheat Field with Cypresses")
        #expect(artwork.sourceURL.absoluteString == "https://www.metmuseum.org/art/collection/search/436535")
        #expect(!artwork.image.hasVerifiedResolution)
        #expect(artwork.themes == ["Cypresses"])
        #expect(source.licensePolicy(for: artwork))
    }

    @Test func metRejectsMissingOrFalseRightsEvenWithAnImageURL() throws {
        for flag in ["false", "null"] {
            let object = try JSONDecoder().decode(MetObject.self, from: Data("""
            {"objectID":1,"isPublicDomain":\(flag),"primaryImage":"https://images.metmuseum.org/a.jpg"}
            """.utf8))
            #expect(throws: ArtworkSourceError.self) { try MetMuseumSource().normalizeMetadata(object) }
        }
    }

    @Test func metDoesNotUseAnOriginalAsAGalleryThumbnail() throws {
        let object = try JSONDecoder().decode(MetObject.self, from: Data("""
        {"objectID":1,"isPublicDomain":true,"primaryImage":"https://images.metmuseum.org/original.jpg"}
        """.utf8))
        #expect(throws: ArtworkSourceError.self) { try MetMuseumSource().normalizeMetadata(object) }
    }

    @Test func aicKeepsSourceImagePixelsAndCC0() throws {
        let object = try JSONDecoder().decode(AICObject.self, from: Data("""
        {"id":27992,"title":"A Sunday on La Grande Jatte","artist_title":"Georges Seurat",
         "is_public_domain":true,"image_id":"2d484387-2509-5e8e-2c43-22f9981972eb",
         "thumbnail":{"width":9310,"height":6237},"date_start":1884,"style_title":"Pointillism"}
        """.utf8))
        let source = AICSource()
        let artwork = try source.normalizeMetadata(object)
        #expect(artwork.image.width == 9310)
        #expect(artwork.image.height == 6237)
        #expect(artwork.image.thumbnailURL.path.contains("/640,/"))
        #expect(artwork.metadataLicense == "CC0 1.0")
        #expect(source.licensePolicy(for: artwork))
        #expect(!MetMuseumSource().licensePolicy(for: artwork))
    }

    @Test func aicRejectsUnverifiedRights() throws {
        let object = try JSONDecoder().decode(AICObject.self, from: Data("""
        {"id":1,"is_public_domain":null,"image_id":"abcd"}
        """.utf8))
        #expect(throws: ArtworkSourceError.self) { try AICSource().normalizeMetadata(object) }
    }

    @Test func museumArtistIdentityAndOptionalDatesAreNormalized() throws {
        let object = try JSONDecoder().decode(MetObject.self, from: Data("""
        {"objectID":436535,"isPublicDomain":true,"primaryImage":"https://images.metmuseum.org/original.jpg",
         "primaryImageSmall":"https://images.metmuseum.org/small.jpg","objectBeginDate":1889,"objectEndDate":1889,
         "metadataDate":"2026-10-20T12:00:00Z","constituents":[{"constituentID":161880,"role":"Artist"}]}
        """.utf8))
        let artwork = try MetMuseumSource().normalizeMetadata(object)
        #expect(artwork.artistID == "met-artist-161880")
        #expect(artwork.yearEnd == 1889)
        #expect(artwork.metadataUpdatedAt == "2026-10-20T12:00:00Z")
        #expect(artwork.image.availableSizes == nil)
    }

    @Test func aicDetailUsesAnIndependentHighResolutionIIIFVariant() throws {
        let object = try JSONDecoder().decode(AICObject.self, from: Data("""
        {"id":27992,"artist_id":36195,"is_public_domain":true,"image_id":"2d484387-2509-5e8e-2c43-22f9981972eb",
         "thumbnail":{"width":9310,"height":6237},"date_end":1886,"updated_at":"2026-10-20T12:00:00Z"}
        """.utf8))
        let artwork = try AICSource().normalizeMetadata(object)
        #expect(artwork.artistID == "aic-artist-36195")
        #expect(artwork.image.detailURL?.path.contains("/2000,/") == true)
        #expect(artwork.image.detailURL != artwork.image.thumbnailURL)
        #expect(artwork.image.availableSizes?.first?.width == 9310)
    }

    @Test func identifierCannotEscapeEndpointPath() {
        for id in ["../objects/1", "met-1?admin=true", "", "aic-3"] {
            #expect(throws: ArtworkSourceError.self) { try MuseumMetadata.numericID(id, source: .met) }
        }
    }
}
