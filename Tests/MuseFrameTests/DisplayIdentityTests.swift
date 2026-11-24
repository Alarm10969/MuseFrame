import AppKit
import Foundation
import Testing
@testable import MuseFrame

@Suite("Persistent display identity and fallback")
struct DisplayIdentityTests {
    private let firstID = "11111111-1111-1111-1111-111111111111"
    private let secondID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    @Test func savedUUIDAndLegacyNumberResolveIndependentlyOfArrayOrder() throws {
        let main = profile(firstID, runtime: 1, main: true)
        let external = profile(secondID, runtime: 42)
        for screens in [[main, external], [external, main]] {
            #expect(try WallpaperTarget.display(secondID).resolve(in: screens, currentID: nil).map(\.id) == [secondID])
            #expect(try WallpaperTarget.display("42").resolve(in: screens, currentID: nil).map(\.id) == [secondID])
            #expect(ScreenProfile.canonicalIdentifier(for: "42", in: screens) == secondID)
            #expect(ScreenProfile.canonicalIdentifier(for: secondID.uppercased(), in: screens) == secondID)
        }
    }

    @Test func savedUUIDSurvivesRuntimeHandleChangeWithoutGuessingUnknownLegacyIDs() throws {
        let reconnected = profile(secondID, runtime: 99)
        let main = profile(firstID, runtime: 1, main: true)
        #expect(reconnected.matchesIdentifier(secondID))
        #expect(!reconnected.matchesIdentifier("42"))
        #expect(ScreenProfile.canonicalIdentifier(for: "42", in: [main, reconnected]) == nil)
        #expect(try WallpaperTarget.display(secondID).resolve(in: [main, reconnected], currentID: nil).first?.runtimeDisplayID == 99)
        #expect(try WallpaperTarget.display("42").resolve(in: [main, reconnected], currentID: nil).map(\.id) == [firstID])
        #expect(ScreenProfile.canonicalIdentifier(for: nil, in: [main]) == nil)
    }

    @Test func missingTargetsFallBackToMainAndReturnWhenMonitorReconnects() throws {
        let main = profile(firstID, runtime: 1, main: true)
        let external = profile(secondID, runtime: 42)
        #expect(try WallpaperTarget.display(secondID).resolve(in: [main], currentID: nil).map(\.id) == [firstID])
        #expect(try WallpaperTarget.current.resolve(in: [main], currentID: secondID).map(\.id) == [firstID])
        #expect(try WallpaperTarget.display(secondID).resolve(in: [external, main], currentID: nil).map(\.id) == [secondID])
        #expect(throws: WallpaperError.self) { try WallpaperTarget.display(secondID).resolve(in: [], currentID: nil) }
    }

    @Test func mainChangeAffectsDefaultTargetButKeepsAnExplicitSavedMonitor() throws {
        let formerMain = profile(firstID, runtime: 1)
        let newMain = profile(secondID, runtime: 42, main: true)
        #expect(try WallpaperTarget.main.resolve(in: [formerMain, newMain], currentID: nil).map(\.id) == [secondID])
        #expect(try WallpaperTarget.display(firstID).resolve(in: [newMain, formerMain], currentID: nil).map(\.id) == [firstID])
        #expect(try WallpaperTarget.current.resolve(in: [newMain, formerMain], currentID: "1").map(\.id) == [firstID])
    }

    @Test func missingMainFlagHasDeterministicFallbackAndAllDisplaysRemainUnique() throws {
        let first = profile(firstID, runtime: 1)
        let second = profile(secondID, runtime: 42)
        for screens in [[first, second], [second, first, second]] {
            #expect(try WallpaperTarget.main.resolve(in: screens, currentID: nil).map(\.id) == [firstID])
            #expect(try WallpaperTarget.display("missing").resolve(in: screens, currentID: nil).map(\.id) == [firstID])
            #expect(try WallpaperTarget.all.resolve(in: screens, currentID: nil).map(\.id) == [firstID, secondID])
        }
    }

    @Test func galleryFitsUsesTheSameLegacyAndDisconnectedFallbackAsWallpaper() throws {
        let main = profile(firstID, runtime: 1, main: true, width: 3200, height: 2000)
        let portrait = profile(secondID, runtime: 42, width: 1440, height: 2560)
        let work = GalleryFilterTests().artwork()
        #expect(GalleryFilter(fitsScreen: true, screenID: "missing").matches(work, screens: [main]))
        #expect(!GalleryFilter(fitsScreen: true, screenID: "42").matches(work, screens: [main, portrait]))
        #expect(!GalleryFilter(fitsScreen: true, screenID: "all").matches(work, screens: [portrait, main]))
    }

    @Test func mixedRetinaDisplaysRetainIndependentBackingPixelFit() throws {
        let standard = profile(firstID, runtime: 1, main: true, width: 1600, height: 1000, scale: 1)
        let retina = profile(secondID, runtime: 42, width: 3200, height: 2000, scale: 2)
        let url = URL(string: "https://images.metmuseum.org/fixture.jpg")!
        let work = Artwork(id: "met-display-fixture", source: .met, sourceID: "fixture", titleOriginal: "Fixture",
            artistOriginal: "Artist", dateDisplay: "1900", museumName: "Museum", sourceURL: url,
            image: ArtworkImage(originalURL: url, thumbnailURL: url, width: 1600, height: 1000, license: "CC0 1.0"), isPublicDomain: true)
        let engine = ScreenFitEngine()
        #expect(engine.evaluate(work, screen: standard).qualifies)
        #expect(!engine.evaluate(work, screen: retina).qualifies)
        #expect(standard.logicalWidth == retina.logicalWidth)
        #expect(!GalleryFilter(fitsScreen: true, screenID: "all").matches(work, screens: [retina, standard]))
    }

    @Test @MainActor func nativeProfilesExposePersistentIDsAndRuntimeMigrationAliases() {
        for profile in ScreenProfile.current() {
            guard let runtime = profile.runtimeDisplayID else { Issue.record("Native display is missing its runtime handle"); continue }
            #expect(profile.id == ScreenProfile.persistentIdentifier(for: runtime))
            #expect(profile.id != String(runtime))
            #expect(profile.matchesIdentifier(String(runtime)))
            #expect(profile.pixelWidth > 0 && profile.pixelHeight > 0)
            #expect(profile.scale > 0)
            #expect(profile.visibleFrame.width <= profile.frame.width)
        }
    }

    private func profile(_ id: String, runtime: UInt32, main: Bool = false,
                         width: Int = 3840, height: Int = 2160, scale: Double = 2) -> ScreenProfile {
        ScreenProfile(id: id, name: "Display", logicalWidth: Double(width) / scale, logicalHeight: Double(height) / scale,
                      pixelWidth: width, pixelHeight: height, scale: scale, isMain: main, runtimeDisplayID: runtime)
    }
}
