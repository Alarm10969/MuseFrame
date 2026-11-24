import Foundation
import Testing
@testable import MuseFrame

@Suite("Widget deep links")
struct DeepLinkTests {
    @Test func generatedArtworkLinksRoundTripUnicodeWithoutAnotherPathComponent() throws {
        for id in ["met-437430", "aic-123", "馆藏-睡莲-123", "作品_é:42"] {
            let link = MuseFrameDeepLink.artwork(id)
            let url = try #require(link.url)
            #expect(MuseFrameDeepLink(url) == link)
            let snapshot = CurrentArtworkSnapshot(artworkID: id, title: "Artwork", artist: "Artist",
                dateDisplay: nil, summary30s: nil, thumbnailURL: nil, updatedAt: .now)
            #expect(snapshot.deepLink == url)
            #expect(MuseFrameDeepLink(try #require(snapshot.deepLink)) == .artwork(id))
        }
    }

    @Test func galleryAndSchemeCaseAreSupported() throws {
        #expect(MuseFrameDeepLink(try #require(MuseFrameDeepLink.gallery.url)) == .gallery)
        #expect(MuseFrameDeepLink(URL(string: "MUSEFRAME://GALLERY/")!) == .gallery)
        #expect(MuseFrameDeepLink(URL(string: "museframe://ARTWORK/met-1")!) == .artwork("met-1"))
    }

    @Test func malformedAndUnownedRoutesAreRejected() {
        let rejected = [
            "https://artwork/met-1", "museframe://unknown/met-1", "museframe:///artwork/met-1",
            "museframe://artwork", "museframe://artwork/", "museframe://artwork//met-1",
            "museframe://artwork/extra/met-1", "museframe://artwork/met-1/", "museframe://gallery/extra",
            "museframe://user@artwork/met-1", "museframe://artwork:8080/met-1",
            "museframe://artwork/met-1?redirect=other", "museframe://artwork/met-1#other",
            "museframe://artwork/%2e%2e", "museframe://artwork/met%2f1", "museframe://artwork/met%5c1",
            "museframe://artwork/%252e%252e", "museframe://artwork/met%00", "museframe://artwork/met%20one"
        ]
        for literal in rejected {
            #expect(URL(string: literal).flatMap { MuseFrameDeepLink($0) } == nil)
        }
        for id in ["", ".", "..", "met/1", "met\\1", "met%2f1", "met?1", "met#1", "met one", "met\n1"] {
            #expect(MuseFrameDeepLink.artwork(id).url == nil)
        }
    }

    @Test func artistAndMovementRoutesRoundTripWithTheSameStrictPayloadRules() throws {
        for link in [MuseFrameDeepLink.artist("met-artist-161947"), .movement("post-impressionism")] {
            #expect(MuseFrameDeepLink(try #require(link.url)) == link)
        }
        for literal in ["museframe://artist/", "museframe://movement/a/b", "museframe://artist/a?extra=1",
                        "museframe://movement/%2e%2e", "museframe://artist/a%2fb"] {
            #expect(URL(string: literal).flatMap { MuseFrameDeepLink($0) } == nil)
        }
    }
}
