import Foundation
import Testing
@testable import MuseFrame

@Suite("Gallery filter combinations")
struct GalleryFilterTests {
    func artwork(status: GuideStatus = .published, withGuide: Bool = true) -> Artwork {
        Artwork(id: "met-1", source: .met, sourceID: "1", titleOriginal: "A River at Sunset", titleZh: "河畔落日",
                artistOriginal: "Claude Monet", artistZh: "克劳德·莫奈", dateDisplay: "1880", yearStart: 1880,
                movement: "Impressionism", movementZh: "印象派", themes: ["风景", "河流"],
                museumName: "Museum", sourceURL: URL(string: "https://www.metmuseum.org/1")!,
                image: ArtworkImage(originalURL: URL(string: "https://images.metmuseum.org/1.jpg")!,
                    thumbnailURL: URL(string: "https://images.metmuseum.org/thumb.jpg")!, width: 6000, height: 3750, license: "CC0 1.0"),
                isPublicDomain: true, guideStatus: status, dominantColors: ["暖色"],
                guide: withGuide ? ArtworkGuide(summary30s: "落日倒映水中。", lookAtPoints: ["水面"], sourceRefs: []) : nil)
    }
    var screen: ScreenProfile {
        ScreenProfile(id: "main", name: "Retina", logicalWidth: 1440, logicalHeight: 900,
            pixelWidth: 2880, pixelHeight: 1800, scale: 2, isMain: true)
    }

    @Test func allSelectedFacetsMustMatch() {
        var filter = GalleryFilter(query: "莫奈 河畔", theme: "风景", attribute: .landscape,
            movement: "Impressionism", color: "暖色", artist: "Claude Monet", fitsScreen: true, withGuide: true)
        #expect(filter.matches(artwork(), screens: [screen]))
        filter.color = "冷色"
        #expect(!filter.matches(artwork(), screens: [screen]))
    }
    @Test func publishedGuideMustActuallyExist() {
        let filter = GalleryFilter(withGuide: true)
        #expect(!filter.matches(artwork(status: .draft), screens: []))
        #expect(!filter.matches(artwork(withGuide: false), screens: []))
    }
    @Test func fitsAllDisplaysRequiresEveryPhysicalResolution() {
        let large = ScreenProfile(id: "large", name: "8K", logicalWidth: 3840, logicalHeight: 2160,
            pixelWidth: 7680, pixelHeight: 4320, scale: 2, isMain: false)
        #expect(GalleryFilter(fitsScreen: true).matches(artwork(), screens: [screen, large]))
        #expect(!GalleryFilter(fitsScreen: true, screenID: "all").matches(artwork(), screens: [screen, large]))
    }
    @Test func latinSearchIsCaseInsensitive() {
        #expect(GalleryFilter(query: "MONET sunset").matches(artwork(), screens: []))
        #expect(!GalleryFilter(query: "Monet portrait").matches(artwork(), screens: []))
    }
    @Test func unknownDimensionsCannotPassOrientationAttributes() {
        let unknown = Artwork(id: "met-2", source: .met, sourceID: "2", titleOriginal: "Untitled",
            artistOriginal: "Artist", dateDisplay: "1900", museumName: "Museum", sourceURL: URL(string: "https://www.metmuseum.org/2")!,
            image: ArtworkImage(originalURL: URL(string: "https://images.metmuseum.org/2.jpg")!,
                thumbnailURL: URL(string: "https://images.metmuseum.org/2-thumb.jpg")!, width: 0, height: 0, license: "CC0 1.0"), isPublicDomain: true)
        for attribute in [ArtworkAttribute.landscape, .portrait, .square, .highResolution] {
            #expect(!GalleryFilter(attribute: attribute).matches(unknown, screens: []))
        }
    }
    @Test func wallpaperRetryRequestRetainsChosenOptions() {
        let request = WallpaperRequest(artwork: artwork(), allScreens: true, screenID: "external", mode: .fit)
        #expect(request.artwork.id == "met-1")
        #expect(request.allScreens)
        #expect(request.screenID == "external")
        #expect(request.mode == .fit)
    }
}
