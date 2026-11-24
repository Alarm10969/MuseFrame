import AppKit
import CoreGraphics
import ColorSync
import Foundation

/// A display's backing pixels are used for image quality; points are retained for UI.
struct ScreenProfile: Identifiable, Hashable, Sendable {
    /// ColorSync UUID used for saved preferences, independent of NSScreen ordering.
    let id: String
    /// Core Graphics identity is only a live-session handle and a migration alias.
    let runtimeDisplayID: UInt32?
    let name: String
    let logicalWidth: Double
    let logicalHeight: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let isMain: Bool
    let frame: CGRect
    let visibleFrame: CGRect

    init(id: String, name: String, logicalWidth: Double, logicalHeight: Double,
         pixelWidth: Int, pixelHeight: Int, scale: Double, isMain: Bool,
         frame: CGRect = .zero, visibleFrame: CGRect = .zero, runtimeDisplayID: UInt32? = nil) {
        self.id = id; self.name = name
        self.runtimeDisplayID = runtimeDisplayID
        self.logicalWidth = logicalWidth; self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.scale = scale; self.isMain = isMain
        self.frame = frame; self.visibleFrame = visibleFrame
    }

    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    func matchesIdentifier(_ identifier: String) -> Bool {
        id.caseInsensitiveCompare(identifier) == .orderedSame
            || runtimeDisplayID.map { identifier == String($0) || identifier == "runtime:\($0)" } == true
    }

    /// Returns a saved UUID when an old live-session number still identifies a connected display.
    /// An unknown identifier is not guessed from array position or monitor name.
    static func canonicalIdentifier(for identifier: String?, in screens: [ScreenProfile]) -> String? {
        guard let identifier else { return nil }
        return screens.first(where: { $0.matchesIdentifier(identifier) })?.id
    }

    static func preferred(in screens: [ScreenProfile]) -> ScreenProfile? {
        let ordered = screens.sorted { $0.id < $1.id }
        return ordered.first(where: \.isMain) ?? ordered.first
    }

    static func persistentIdentifier(for displayID: UInt32) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let value = CFUUIDCreateString(nil, uuid) else { return "runtime:\(displayID)" }
        return (value as String).lowercased()
    }

    @MainActor
    static func current() -> [ScreenProfile] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(displayID)
            let scale = screen.backingScaleFactor
            let backingWidth = Int((screen.frame.width * scale).rounded())
            let backingHeight = Int((screen.frame.height * scale).rounded())
            return ScreenProfile(
                id: persistentIdentifier(for: displayID),
                name: screen.localizedName,
                logicalWidth: screen.frame.width,
                logicalHeight: screen.frame.height,
                pixelWidth: mode?.pixelWidth ?? backingWidth,
                pixelHeight: mode?.pixelHeight ?? backingHeight,
                scale: scale,
                isMain: displayID == mainID,
                frame: screen.frame, visibleFrame: screen.visibleFrame, runtimeDisplayID: displayID
            )
        }
    }
}

struct ScreenFitResult: Sendable {
    let score: Double
    let cropLoss: Double
    /// Ratio after cover cropping, so a large original cannot hide insufficient visible pixels.
    let resolutionRatio: Double
    let focalRetention: Double
    let qualifies: Bool
    let grade: String
    /// Coordinates in the source image, matching macOS centered Fill Screen.
    let cropRect: NormalizedRect
}

/// A deterministic first version: geometric crop, backing pixel resolution, and curated focal safety.
/// It evaluates centered fill; it does not pretend to perform Vision-based Smart Crop.
struct ScreenFitEngine: Sendable {
    private let maximumCropLoss = 0.22
    private let minimumResolutionRatio = 0.80
    private let minimumFocalRetention = 0.85
    private let minimumScore = 0.80

    func evaluate(_ artwork: Artwork, screen: ScreenProfile) -> ScreenFitResult {
        guard artwork.image.width > 0, artwork.image.height > 0,
              screen.pixelWidth > 0, screen.pixelHeight > 0 else {
            return ScreenFitResult(
                score: 0, cropLoss: 1, resolutionRatio: 0, focalRetention: 0,
                qualifies: false, grade: "Unsuitable",
                cropRect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            )
        }

        let imageWidth = Double(artwork.image.width)
        let imageHeight = Double(artwork.image.height)
        let artworkAspect = imageWidth / imageHeight
        let screenAspect = screen.aspectRatio
        let visibleWidth = min(1, screenAspect / artworkAspect)
        let visibleHeight = min(1, artworkAspect / screenAspect)
        let crop = NormalizedRect(
            x: (1 - visibleWidth) / 2,
            y: (1 - visibleHeight) / 2,
            width: visibleWidth,
            height: visibleHeight
        )
        let visibleRatio = visibleWidth * visibleHeight
        let cropLoss = 1 - visibleRatio
        let resolution = min(
            imageWidth * visibleWidth / Double(screen.pixelWidth),
            imageHeight * visibleHeight / Double(screen.pixelHeight)
        )
        let retention = artwork.image.focalRegion.map { focalRetention(of: $0, in: crop) } ?? 1
        let score = 0.55 * visibleRatio + 0.25 * retention + 0.20 * min(1, resolution)
        let qualifies = cropLoss <= maximumCropLoss + 0.000_001
            && resolution >= minimumResolutionRatio - 0.000_001
            && retention >= minimumFocalRetention - 0.000_001
            && score >= minimumScore
        let grade: String
        if !qualifies {
            grade = "Unsuitable"
        } else if cropLoss <= 0.08 + 0.000_001 {
            grade = "Excellent"
        } else if cropLoss <= 0.15 + 0.000_001 {
            grade = "Good"
        } else {
            grade = "Acceptable"
        }
        return ScreenFitResult(
            score: score,
            cropLoss: cropLoss,
            resolutionRatio: resolution,
            focalRetention: retention,
            qualifies: qualifies,
            grade: grade,
            cropRect: crop
        )
    }

    /// Invalid curated coordinates fail conservatively instead of granting a perfect score.
    private func focalRetention(of focal: NormalizedRect, in crop: NormalizedRect) -> Double {
        guard focal.x.isFinite, focal.y.isFinite, focal.width.isFinite, focal.height.isFinite,
              focal.width > 0, focal.height > 0,
              focal.x >= 0, focal.y >= 0,
              focal.x + focal.width <= 1.000_001,
              focal.y + focal.height <= 1.000_001 else { return 0 }
        let width = max(0, min(focal.x + focal.width, crop.x + crop.width) - max(focal.x, crop.x))
        let height = max(0, min(focal.y + focal.height, crop.y + crop.height) - max(focal.y, crop.y))
        return min(1, width * height / (focal.width * focal.height))
    }
}
