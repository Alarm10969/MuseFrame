import Foundation
import Testing
@testable import MuseFrame

struct ScreenFitTests {
    let engine = ScreenFitEngine()

    @Test func exactAspectAndEnoughBackingPixelsQualify() {
        let result = engine.evaluate(artwork(width: 6_000, height: 3_750), screen: screen(width: 3_200, height: 2_000))
        #expect(result.qualifies)
        #expect(result.grade == "Excellent")
        #expect(abs(result.score - 1) < 0.000_001)
        #expect(abs(result.cropLoss) < 0.000_001)
        #expect(result.cropRect == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func ratiosHaveDifferentCropResultsIncludingUltrawide() {
        let work = artwork(width: 6_000, height: 4_000)
        let threeTwo = engine.evaluate(work, screen: screen(width: 3_000, height: 2_000))
        let sixteenTen = engine.evaluate(work, screen: screen(width: 3_200, height: 2_000))
        let sixteenNine = engine.evaluate(work, screen: screen(width: 3_840, height: 2_160))
        let ultrawide = engine.evaluate(work, screen: screen(width: 3_440, height: 1_440))
        #expect(threeTwo.qualifies)
        #expect(sixteenTen.qualifies)
        #expect(sixteenNine.qualifies)
        #expect(!ultrawide.qualifies)
        #expect(threeTwo.cropLoss < sixteenTen.cropLoss)
        #expect(sixteenTen.cropLoss < sixteenNine.cropLoss)
        #expect(sixteenNine.cropLoss < ultrawide.cropLoss)
        #expect(abs(sixteenNine.cropLoss - 0.15625) < 0.000_001)
        #expect(sixteenNine.grade == "Acceptable")
    }

    @Test func portraitIsNotMistakenForWallpaperAtHighResolution() {
        let result = engine.evaluate(artwork(width: 6_000, height: 9_000), screen: screen(width: 3_200, height: 2_000))
        #expect(!result.qualifies)
        #expect(result.cropLoss > 0.5)
        #expect(result.resolutionRatio > 1)
    }

    @Test func backingPixelsRatherThanLogicalPointsDetermineResolution() {
        let retina = screen(width: 3_200, height: 2_000)
        let lowResolution = engine.evaluate(artwork(width: 1_600, height: 1_000), screen: retina)
        let threshold = engine.evaluate(artwork(width: 2_560, height: 1_600), screen: retina)
        let justBelow = engine.evaluate(artwork(width: 2_559, height: 1_600), screen: retina)
        #expect(!lowResolution.qualifies)
        #expect(abs(lowResolution.resolutionRatio - 0.5) < 0.000_001)
        #expect(threshold.qualifies)
        #expect(!justBelow.qualifies)
    }

    @Test func visiblePixelsAfterCropDetermineResolution() {
        // Total area exceeds the target, but the cropped height cannot fill its physical pixels.
        let result = engine.evaluate(artwork(width: 5_000, height: 1_000), screen: screen(width: 3_200, height: 2_000))
        #expect(abs(result.resolutionRatio - 0.5) < 0.000_001)
        #expect(!result.qualifies)
    }

    @Test func unknownOrInvalidDimensionsNeverQualify() {
        for dimensions in [(0, 0), (0, 4_000), (4_000, 0), (-1, 4_000)] {
            let result = engine.evaluate(artwork(width: dimensions.0, height: dimensions.1), screen: screen(width: 3_200, height: 2_000))
            #expect(!result.qualifies)
            #expect(result.score == 0)
            #expect(result.resolutionRatio == 0)
        }
        let invalidDisplay = engine.evaluate(artwork(width: 6_000, height: 4_000), screen: screen(width: 0, height: 0))
        #expect(!invalidDisplay.qualifies)
        #expect(invalidDisplay.score.isFinite)
    }

    @Test func centerFillPreviewHasCorrectSourceCoordinates() {
        let result = engine.evaluate(artwork(width: 6_000, height: 4_000), screen: screen(width: 3_840, height: 2_160))
        #expect(abs(result.cropRect.x) < 0.000_001)
        #expect(abs(result.cropRect.y - 0.078125) < 0.000_001)
        #expect(abs(result.cropRect.width - 1) < 0.000_001)
        #expect(abs(result.cropRect.height - 0.84375) < 0.000_001)
        let visibleAspect = 6_000 * result.cropRect.width / (4_000 * result.cropRect.height)
        #expect(abs(visibleAspect - 16.0 / 9.0) < 0.000_001)
    }

    @Test func focalRegionClippedAtTheEdgeIsRejected() {
        let work = artwork(width: 6_000, height: 4_000, focal: NormalizedRect(x: 0.4, y: 0, width: 0.2, height: 0.15))
        let result = engine.evaluate(work, screen: screen(width: 3_840, height: 2_160))
        #expect(result.cropLoss < 0.22)
        #expect(result.resolutionRatio >= 1)
        #expect(result.focalRetention < 0.85)
        #expect(!result.qualifies)
    }

    @Test func retainedFocalRegionStillQualifies() {
        let work = artwork(width: 6_000, height: 4_000, focal: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let result = engine.evaluate(work, screen: screen(width: 3_840, height: 2_160))
        #expect(abs(result.focalRetention - 1) < 0.000_001)
        #expect(result.qualifies)
    }

    @Test func malformedFocalRegionFailsConservatively() {
        let work = artwork(width: 6_000, height: 4_000, focal: NormalizedRect(x: .nan, y: 0.25, width: 0.5, height: 0.5))
        let result = engine.evaluate(work, screen: screen(width: 3_840, height: 2_160))
        #expect(result.focalRetention == 0)
        #expect(result.score.isFinite)
        #expect(!result.qualifies)
    }

    private func screen(width: Int, height: Int) -> ScreenProfile {
        ScreenProfile(id: "test-\(width)-\(height)", name: "Test Retina Display",
                      logicalWidth: Double(width) / 2, logicalHeight: Double(height) / 2,
                      pixelWidth: width, pixelHeight: height, scale: 2, isMain: true)
    }

    private func artwork(width: Int, height: Int, focal: NormalizedRect? = nil) -> Artwork {
        let url = URL(string: "https://example.org/public-domain.jpg")!
        return Artwork(id: "test-work", source: .met, sourceID: "test-work",
                       titleOriginal: "Test Work", artistOriginal: "Test Artist", dateDisplay: "1900",
                       museumName: "Test Museum", sourceURL: url,
                       image: ArtworkImage(originalURL: url, thumbnailURL: url, width: width, height: height,
                                           license: "CC0 1.0", focalRegion: focal),
                       isPublicDomain: true)
    }
}
