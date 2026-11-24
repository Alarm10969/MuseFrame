import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import MuseFrame

struct ImagePipelineTests {
    @Test func cachedOriginalMigratesLazilyAndSurvivesRemovalOfThePrivateCache() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldRoot = fixture.root.appendingPathComponent("Old")
        let old = ImageCache(directory: oldRoot)
        let oldURL = try await old.fileURL(for: fixture.artwork, purpose: .wallpaper)
        let shared = ImageCache(directory: fixture.root.appendingPathComponent("Shared"), legacyDirectory: oldRoot)
        let migrated = try #require(await shared.cachedFileURL(for: fixture.artwork, purpose: .wallpaper))
        #expect(migrated != oldURL)
        #expect(try Data(contentsOf: migrated) == Data(contentsOf: oldURL))
        try FileManager.default.removeItem(at: oldRoot)
        #expect(await shared.cachedFileURL(for: fixture.artwork, purpose: .wallpaper) == migrated)
        try await shared.clear()
        #expect(await shared.cachedFileURL(for: fixture.artwork, purpose: .wallpaper) == nil)
    }

    @Test func separateCacheTiersDownsampleWithoutReplacingOriginal() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        let thumbnail = try await cache.fileURL(for: fixture.artwork, purpose: .thumbnail)
        let detail = try await cache.fileURL(for: fixture.artwork, purpose: .detail)
        let wallpaper = try await cache.fileURL(for: fixture.artwork, purpose: .wallpaper)
        #expect(Set([thumbnail, detail, wallpaper]).count == 3)
        #expect(imageWidth(at: thumbnail) == 640)
        #expect(imageWidth(at: detail) == 2_000)
        #expect(imageWidth(at: wallpaper) == 2_048)
        #expect(try Data(contentsOf: wallpaper) == Data(contentsOf: fixture.artwork.image.originalURL))
    }

    @Test func concurrentImageRequestsResolveToOneValidCachedFile() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appendingPathComponent("Cache")
        let cache = ImageCache(directory: directory)
        let urls = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<24 {
                group.addTask { try await cache.fileURL(for: fixture.artwork, purpose: .thumbnail) }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        #expect(Set(urls).count == 1)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(imageWidth(at: urls[0]) == 640)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("thumbnail"),
                                                                 includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }

    @Test func cancellationDoesNotPreventAnotherSubscriberFromLoading() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        let cancelled = Task { try await cache.fileURL(for: fixture.artwork, purpose: .thumbnail) }
        let survivor = Task { try await cache.fileURL(for: fixture.artwork, purpose: .thumbnail) }
        await Task.yield()
        cancelled.cancel()
        do {
            // Finishing just before cancellation is valid; either outcome must preserve the other request.
            let completed = try await cancelled.value
            #expect(imageWidth(at: completed) == 640)
        } catch is CancellationError {
        }
        let file = try await survivor.value
        #expect(imageWidth(at: file) == 640)
    }

    @Test func invalidImageFailsWithoutLeavingPartialCacheFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.jpg")
        try Data("Not an image".utf8).write(to: source)
        let cacheDirectory = root.appendingPathComponent("Cache")
        let cache = ImageCache(directory: cacheDirectory)
        do {
            _ = try await cache.fileURL(for: work(imageURL: source, width: 100, height: 100), purpose: .thumbnail)
            Issue.record("Invalid image should not be cached")
        } catch ImageCacheError.invalidImage {
        }
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory.appendingPathComponent("thumbnail"),
                                                                 includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test @MainActor func appliedWallpaperCopySurvivesCacheClearWithoutChangingDesktop() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        let cached = try await cache.fileURL(for: fixture.artwork, purpose: .wallpaper)
        let applied = try WallpaperEngine().prepareDesktopImage(cached, artwork: fixture.artwork,
                                                                directory: fixture.root.appendingPathComponent("Applied"))
        try await cache.clear()
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(FileManager.default.fileExists(atPath: applied.path))
        #expect(imageWidth(at: applied) == 2_048)
        #expect(try Data(contentsOf: applied) == Data(contentsOf: fixture.artwork.image.originalURL))
    }

    @Test func cacheLimitNeverDeletesTheFileItIsReturning() async throws {
        let fixture = try imageFixture(width: 640, height: 640, noise: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"), limitBytes: 1_048_576)
        let file = try await cache.fileURL(for: fixture.artwork, purpose: .wallpaper)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(imageWidth(at: file) == 640)
    }

    @Test func offlineLookupKeepsImageTiersDistinctAndClearRemovesCachedOriginals() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .thumbnail) == nil)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .wallpaper) == nil)
        let thumbnail = try await cache.fileURL(for: fixture.artwork, purpose: .thumbnail)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .thumbnail) == thumbnail)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .detail) == nil)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .wallpaper) == nil)
        let wallpaper = try await cache.fileURL(for: fixture.artwork, purpose: .wallpaper)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .wallpaper) == wallpaper)
        try await cache.clear()
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .wallpaper) == nil)
        #expect(!FileManager.default.fileExists(atPath: wallpaper.path))
    }

    @Test func detailUsesDedicatedMediumURLInsteadOfGalleryThumbnail() async throws {
        let original = try imageFixture(width: 2_048)
        let medium = try imageFixture(width: 1_600, height: 800)
        let small = try imageFixture(width: 320, height: 160)
        defer {
            for fixture in [original, medium, small] { try? FileManager.default.removeItem(at: fixture.root) }
        }
        let artwork = work(imageURL: original.artwork.image.originalURL, width: 2_048, height: 1_024,
            thumbnailURL: small.artwork.image.originalURL, detailURL: medium.artwork.image.originalURL)
        let cache = ImageCache(directory: original.root.appendingPathComponent("Cache"))
        #expect(imageWidth(at: try await cache.fileURL(for: artwork, purpose: .thumbnail)) == 320)
        #expect(imageWidth(at: try await cache.fileURL(for: artwork, purpose: .detail)) == 1_600)
        #expect(imageWidth(at: try await cache.fileURL(for: artwork, purpose: .wallpaper)) == 2_048)
    }

    @Test func concurrentDecodeSharesImmutableBitmapAndRetinaSizesHaveSeparateEntries() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        async let first = cache.decodedImage(for: fixture.artwork, purpose: .detail, maxPixelSize: 900)
        async let second = cache.decodedImage(for: fixture.artwork, purpose: .detail, maxPixelSize: 900)
        let (a, b) = try await (first, second)
        #expect(a.image === b.image)
        #expect(a.image.width == 900)
        let smaller = try await cache.decodedImage(for: fixture.artwork, purpose: .detail, maxPixelSize: 450)
        #expect(smaller.image.width == 450)
        #expect(smaller.image !== a.image)
        let bounded = try await cache.decodedImage(for: fixture.artwork, purpose: .detail, maxPixelSize: 10_000)
        #expect(bounded.image.width == 2_000)
    }

    @Test func memoryPressureClearsDecodedImagesWhileKeepingOfflineFiles() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"))
        let first = try await cache.decodedImage(for: fixture.artwork, purpose: .thumbnail, maxPixelSize: 500)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .thumbnail) == nil)
        await cache.clearMemoryCache()
        let second = try await cache.decodedImage(for: fixture.artwork, purpose: .thumbnail, maxPixelSize: 500)
        #expect(first.image !== second.image)
        #expect(first.image.width == second.image.width)
        #expect(await cache.cachedFileURL(for: fixture.artwork, purpose: .thumbnail) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Cache").path))
    }

    @Test func bitmapAboveMemoryBudgetIsNotRetained() async throws {
        let fixture = try imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = ImageCache(directory: fixture.root.appendingPathComponent("Cache"), memoryLimitBytes: 4)
        let first = try await cache.decodedImage(for: fixture.artwork, purpose: .thumbnail, maxPixelSize: 400)
        let second = try await cache.decodedImage(for: fixture.artwork, purpose: .thumbnail, maxPixelSize: 400)
        #expect(first.image !== second.image)
        #expect(first.image.width == 400)
        #expect(second.image.width == 400)
    }

    @Test @MainActor func browsingAndSavingOneHundredWorksWritesNoImageFiles() async throws {
        let fixture = try imageFixture(width: 100, height: 80)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appendingPathComponent("Cache")
        let cache = ImageCache(directory: directory)
        let container = try ModelContainer(for: SavedArtwork.self,
            configurations: ModelConfiguration(url: fixture.root.appendingPathComponent("saved.store")))
        let history = ArtHistoryRepository(historyURL: fixture.root.appendingPathComponent("history.json"),
            guidesURL: fixture.root.appendingPathComponent("guides.json"))
        let model = AppModel(modelContainer: container, rotation: RotationEngine(storageURL: fixture.root.appendingPathComponent("rotation")),
            currentStore: CurrentArtworkStore(directory: fixture.root.appendingPathComponent("current"), reloadTimelines: {}),
            autoStart: false, historyRepository: history)
        for index in 0..<100 {
            let source = fixture.root.appendingPathComponent("work-\(index).jpg")
            try FileManager.default.linkItem(at: fixture.artwork.image.originalURL, to: source)
            let artwork = work(imageURL: source, width: 100, height: 80, id: "work-\(index)")
            _ = try await cache.decodedImage(for: artwork, purpose: .thumbnail, maxPixelSize: 80)
            _ = try await cache.decodedImage(for: artwork, purpose: .detail, maxPixelSize: 100)
            model.toggleSaved(artwork)
        }
        let saved = try ModelContext(container).fetch(FetchDescriptor<SavedArtwork>())
        #expect(saved.count == 100)
        #expect(saved.allSatisfy { (try? JSONDecoder().decode(Artwork.self, from: $0.snapshot).id) == $0.artworkID })
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func imageWidth(at url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
    }

    private func imageFixture(width: Int = 2_048, height: Int = 1_024, noise: Bool = false) throws -> (root: URL, artwork: Artwork) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var random: UInt32 = 0x1234_5678
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if noise {
                    random ^= random << 13
                    random ^= random >> 17
                    random ^= random << 5
                }
                bytes[index] = noise ? UInt8(truncatingIfNeeded: random) : 112
                bytes[index + 1] = noise ? UInt8(truncatingIfNeeded: random >> 8) : 137
                bytes[index + 2] = noise ? UInt8(truncatingIfNeeded: random >> 16) : 159
                bytes[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (root, work(imageURL: source, width: width, height: height))
    }

    private func work(imageURL: URL, width: Int, height: Int, thumbnailURL: URL? = nil,
                      detailURL: URL? = nil, id: String? = nil, bundledSource: URL? = nil) -> Artwork {
        Artwork(id: id ?? "cache-test-\(UUID().uuidString)", source: .met, sourceID: "fixture",
                titleOriginal: "Fixture", artistOriginal: "Fixture Artist", dateDisplay: "1900",
                museumName: "Fixture Museum", sourceURL: imageURL,
                image: ArtworkImage(originalURL: imageURL, thumbnailURL: thumbnailURL ?? imageURL,
                                    width: width, height: height, license: "CC0 1.0", detailURL: detailURL,
                                    bundledThumbnailSourceURL: bundledSource),
                isPublicDomain: true)
    }
}
