import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MuseFrame

@Suite("Desktop wallpaper preparation")
struct WallpaperEngineTests {
    @Test func targetResolutionUsesCurrentMainSpecificOrAllDisplays() throws {
        let main = screen("main", width: 3_200, height: 2_000, main: true)
        let external = screen("external", width: 3_840, height: 2_160)
        let portrait = screen("portrait", width: 1_440, height: 2_560)
        let screens = [main, external, portrait]
        #expect(try WallpaperTarget.main.resolve(in: screens, currentID: external.id).map(\.id) == [main.id])
        let current = try WallpaperTarget.current.resolve(in: screens, currentID: external.id)
        #expect(current.first?.pixelWidth == 3_840)
        #expect(current.first?.pixelHeight == 2_160)
        #expect(current.first?.scale == 2)
        #expect(try WallpaperTarget.display(portrait.id).resolve(in: screens, currentID: nil).map(\.id) == [portrait.id])
        #expect(try WallpaperTarget.all.resolve(in: screens, currentID: nil).map(\.id) == screens.map(\.id).sorted())
    }

    @Test func disconnectedCurrentAndSavedTargetsFallBackToMain() throws {
        let main = screen("main", width: 3_200, height: 2_000, main: true)
        #expect(try WallpaperTarget.current.resolve(in: [main], currentID: "unplugged").map(\.id) == [main.id])
        #expect(try WallpaperTarget.display("unplugged").resolve(in: [main], currentID: nil).map(\.id) == [main.id])
        #expect(throws: WallpaperError.self) { try WallpaperTarget.all.resolve(in: [], currentID: nil) }
    }

    @Test func cropGeometryMatchesCenteredCoverForLandscapeAndPortrait() {
        let crop = DesktopCropRenderer.cropRect(imageWidth: 6_000, imageHeight: 4_000,
                                                targetWidth: 3_840, targetHeight: 2_160)
        #expect(abs(crop.x) < 0.000_001)
        #expect(abs(crop.y - 0.078125) < 0.000_001)
        #expect(abs(crop.height - 0.84375) < 0.000_001)
        let wide = DesktopCropRenderer.cropRect(imageWidth: 6_000, imageHeight: 2_000,
                                                targetWidth: 2_000, targetHeight: 2_000)
        #expect(abs(wide.x - 1.0 / 3) < 0.000_001)
        #expect(abs(wide.width - 1.0 / 3) < 0.000_001)
        let portrait = DesktopCropRenderer.cropRect(imageWidth: 2_000, imageHeight: 6_000,
                                                    targetWidth: 2_000, targetHeight: 2_000)
        #expect(abs(portrait.y - 1.0 / 3) < 0.000_001)
        #expect(abs(portrait.height - 1.0 / 3) < 0.000_001)
        let invalid = DesktopCropRenderer.cropRect(imageWidth: .infinity, imageHeight: 0, targetWidth: 100, targetHeight: 100)
        #expect(invalid == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func rendererProducesExactBackingPixelsAndKeepsTheImageCenter() throws {
        let fixture = try stripedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = try DesktopCropRenderer.render(fixture.source, width: 200, height: 200)
        let image = try decoded(output)
        #expect(image.width == 200)
        #expect(image.height == 200)
        // The 600x200 fixture is red / green / blue. A square centered crop is green.
        for x in [20, 100, 180] {
            let color = try pixel(image, x: x, y: 100)
            #expect(color.green > 180)
            #expect(color.red < 60)
            #expect(color.blue < 60)
        }
        #expect(image.colorSpace?.model == .rgb)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test func rendererHonorsEXIFOrientationBeforeCropping() throws {
        let fixture = try stripedFixture(orientation: 6)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = try DesktopCropRenderer.render(fixture.source, width: 100, height: 300)
        let image = try decoded(output)
        #expect(image.width == 100)
        #expect(image.height == 300)
        let top = try pixel(image, x: 50, y: 50)
        let middle = try pixel(image, x: 50, y: 150)
        let bottom = try pixel(image, x: 50, y: 250)
        #expect(middle.green > 180)
        #expect(top.green < 60)
        #expect(bottom.green < 60)
        #expect(top.red > 180 || top.blue > 180)
        #expect(bottom.red > 180 || bottom.blue > 180)
        #expect(abs(Int(top.red) - Int(bottom.red)) > 150)
    }

    @Test func cropCacheIsReusedAndSourceUpdatesGetANewRetainedFile() throws {
        let fixture = try stripedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try DesktopCropRenderer.render(fixture.source, width: 200, height: 200)
        let reused = try DesktopCropRenderer.render(fixture.source, width: 200, height: 200)
        #expect(first == reused)
        let differentDisplay = try DesktopCropRenderer.render(fixture.source, width: 160, height: 90)
        #expect(differentDisplay != first)
        let previousDate = try fixture.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
        try FileManager.default.setAttributes([.modificationDate: previousDate.addingTimeInterval(60)], ofItemAtPath: fixture.source.path)
        let updated = try DesktopCropRenderer.render(fixture.source, width: 200, height: 200)
        #expect(updated != first)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: updated.path))
    }

    @Test func concurrentCropRequestsFinishWithOneValidAtomicOutput() async throws {
        let fixture = try stripedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let urls = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<8 {
                group.addTask { try DesktopCropRenderer.render(fixture.source, width: 200, height: 200) }
            }
            var result: [URL] = []
            for try await output in group { result.append(output) }
            return result
        }
        #expect(Set(urls).count == 1)
        #expect(try decoded(#require(urls.first)).width == 200)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        #expect(!remaining.contains { $0.pathExtension == "partial" })
    }

    @Test func invalidRasterAndExcessiveTargetDimensionsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: invalid)
        #expect(throws: DesktopCropError.self) { try DesktopCropRenderer.render(invalid, width: 100, height: 100) }
        #expect(throws: DesktopCropError.self) { try DesktopCropRenderer.render(invalid, width: 0, height: 100) }
        #expect(throws: DesktopCropError.self) { try DesktopCropRenderer.render(invalid, width: Int.max, height: Int.max) }
        #expect(throws: DesktopCropError.self) {
            try DesktopCropRenderer.render(URL(string: "https://example.org/image.jpg")!, width: 100, height: 100)
        }
    }

    @Test @MainActor func unconfirmedRightsAndMissingDisplayFailBeforeDesktopAccess() async throws {
        let applier = UnusedDesktopApplier()
        let engine = WallpaperEngine(applier: applier)
        for artwork in [work(publicDomain: false), work(publicDomain: true, license: " ")] {
            do {
                try await engine.set(artwork, on: [])
                Issue.record("Unconfirmed rights should reject a wallpaper request")
            } catch WallpaperError.rightsNotConfirmed {}
        }
        do {
            try await engine.set(work(publicDomain: true), on: [])
            Issue.record("An empty target should reject a wallpaper request")
        } catch WallpaperError.noDisplay {}
        #expect(applier.accessCount == 0)
    }

    @Test @MainActor func failedSecondDisplayRestoresAllAttemptedDisplayStates() throws {
        let original = ["a": "old-a/fit", "b": "old-b/fill", "c": "old-c/fit"]
        var state = original
        var events: [String] = []
        do {
            try WallpaperApplicationTransaction.perform(displayIDs: ["a", "b", "c"], apply: { id in
                events.append("apply-\(id)")
                state[id] = "new/centerCrop"
                if id == "b" { throw DesktopFixtureError.applyFailed }
            }, rollback: { id in
                events.append("restore-\(id)")
                state[id] = original[id]
            })
            Issue.record("The failed desktop setter must not produce a successful transaction")
        } catch WallpaperError.applyFailed {}
        #expect(state == original)
        #expect(events == ["apply-a", "apply-b", "restore-b", "restore-a"])
    }

    @Test @MainActor func rollbackContinuesAfterARecoveryFailureAndReportsBothErrors() throws {
        var events: [String] = []
        do {
            try WallpaperApplicationTransaction.perform(displayIDs: ["a", "b", "c"], apply: { id in
                events.append("apply-\(id)")
                if id == "c" { throw DesktopFixtureError.applyFailed }
            }, rollback: { id in
                events.append("restore-\(id)")
                if id == "c" { throw DesktopFixtureError.restoreFailed }
            })
            Issue.record("An application and recovery failure must be reported")
        } catch WallpaperError.applyFailed(let message) {
            #expect(message.contains("fixture apply failure"))
            #expect(message.contains("fixture restore failure"))
        }
        #expect(events == ["apply-a", "apply-b", "apply-c", "restore-c", "restore-b", "restore-a"])
    }

    @Test @MainActor func cancellationBeforeTheTransactionPerformsNoDesktopWrites() async throws {
        var writes = 0
        let task = Task { @MainActor in
            try WallpaperApplicationTransaction.perform(displayIDs: ["a", "b"], apply: { _ in writes += 1 }, rollback: { _ in writes += 1 })
        }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled work should not apply wallpaper") }
        catch is CancellationError {}
        #expect(writes == 0)
    }

    @Test func concurrentDesktopCopiesPublishOneCompleteRetainedFile() async throws {
        let fixture = try stripedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appendingPathComponent("Applied")
        let urls = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try WallpaperEngine.persistDesktopImage(fixture.source, originalURL: fixture.source, in: directory)
                }
            }
            var result: [URL] = []
            for try await url in group { result.append(url) }
            return result
        }
        #expect(Set(urls).count == 1)
        let published = try #require(urls.first)
        #expect(try Data(contentsOf: published) == Data(contentsOf: fixture.source))
        #expect(try decoded(published).width == 600)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1)
    }

    @Test @MainActor func authorizationRejectionOrOmittedOperationCannotReturnSuccess() async throws {
        guard let screen = NSScreen.screens.first else { return }
        let fixture = try stripedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let work = localArtwork(fixture.source)
        let applier = RecordingDesktopApplier()
        let engine = WallpaperEngine(cache: ImageCache(directory: fixture.root.appendingPathComponent("Cache")),
            applier: applier, appliedDirectory: fixture.root.appendingPathComponent("Applied"))
        for reject in [true, false] {
            do {
                _ = try await engine.set(work, on: [screen], authorizeApply: { _ in
                    if reject { throw CancellationError() }
                })
                Issue.record("A rejected or unused authorization cannot report a desktop change")
            } catch is CancellationError {}
        }
        #expect(applier.accessCount == 0)
        #expect(applier.appliedFiles.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Applied").path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Cache/wallpaper").path))
    }

    @Test @MainActor func authorizedNativeTransactionUsesPersistentIdentityAndDurableFile() async throws {
        guard let screen = NSScreen.screens.first else { return }
        let fixture = try stripedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let work = localArtwork(fixture.source)
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        let applier = RecordingDesktopApplier()
        let directory = fixture.root.appendingPathComponent("Applied")
        let engine = WallpaperEngine(cache: cache, applier: applier, appliedDirectory: directory)
        var authorizations = 0
        let receipt = try await engine.set(work, on: [screen], mode: .fit, authorizeApply: { operation in
            authorizations += 1
            try operation()
        })
        #expect(authorizations == 1)
        #expect(receipt.displayIDs == [try #require(WallpaperEngine.identifier(of: screen))])
        #expect(applier.appliedFiles == [receipt.localImageURL])
        #expect((applier.lastOptions[.allowClipping] as? Bool) == false)
        try await cache.clear()
        #expect(FileManager.default.fileExists(atPath: receipt.localImageURL.path))
        #expect(engine.existingDesktopImage(for: work)?.resolvingSymlinksInPath().path == receipt.localImageURL.resolvingSymlinksInPath().path)
    }

    private func localArtwork(_ source: URL) -> Artwork {
        Artwork(id: "met-local-\(UUID().uuidString)", source: .met, sourceID: "fixture", titleOriginal: "Fixture",
            artistOriginal: "Artist", dateDisplay: "1900", museumName: "Museum", sourceURL: source,
            image: ArtworkImage(originalURL: source, thumbnailURL: source, width: 600, height: 200, license: "CC0 1.0"), isPublicDomain: true)
    }

    private func screen(_ id: String, width: Int, height: Int, main: Bool = false) -> ScreenProfile {
        ScreenProfile(id: id, name: id, logicalWidth: Double(width) / 2, logicalHeight: Double(height) / 2,
                      pixelWidth: width, pixelHeight: height, scale: 2, isMain: main)
    }

    private func work(publicDomain: Bool, license: String = "CC0 1.0") -> Artwork {
        let url = URL(string: "https://example.org/never-requested-\(UUID().uuidString).jpg")!
        return Artwork(id: UUID().uuidString, source: .met, sourceID: "fixture", titleOriginal: "Fixture",
                       artistOriginal: "Artist", dateDisplay: "1900", museumName: "Museum", sourceURL: url,
                       image: ArtworkImage(originalURL: url, thumbnailURL: url, width: 600, height: 200, license: license),
                       isPublicDomain: publicDomain)
    }

    private func stripedFixture(orientation: Int = 1) throws -> (root: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuseFrame-Crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jpg")
        let width = 600
        let height = 200
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    bytes[offset] = x < 200 ? 255 : 0
                    bytes[offset + 1] = (200..<400).contains(x) ? 255 : 0
                    bytes[offset + 2] = x >= 400 ? 255 : 0
                    bytes[offset + 3] = 255
                }
            }
        }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.98,
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (root, source)
    }

    private func decoded(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -Double(x), y: -Double(y), width: Double(image.width), height: Double(image.height)))
        }
        return (bytes[0], bytes[1], bytes[2])
    }
}

@MainActor private final class UnusedDesktopApplier: DesktopImageApplying {
    private(set) var accessCount = 0

    func currentURL(for screen: NSScreen) -> URL? { accessCount += 1; return nil }
    func currentOptions(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any] { accessCount += 1; return [:] }
    func apply(_ file: URL, to screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        accessCount += 1
        Issue.record("The unit test must never apply a desktop image")
    }
}

private enum DesktopFixtureError: LocalizedError {
    case applyFailed, restoreFailed
    var errorDescription: String? { self == .applyFailed ? "fixture apply failure" : "fixture restore failure" }
}

@MainActor private final class RecordingDesktopApplier: DesktopImageApplying {
    private(set) var accessCount = 0
    private(set) var appliedFiles: [URL] = []
    private(set) var lastOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [:]

    func currentURL(for screen: NSScreen) -> URL? { accessCount += 1; return URL(fileURLWithPath: "/fixture/previous.jpg") }
    func currentOptions(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        accessCount += 1
        return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
    }
    func apply(_ file: URL, to screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        accessCount += 1
        appliedFiles.append(file)
        lastOptions = options
    }
}
