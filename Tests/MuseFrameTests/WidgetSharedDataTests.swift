import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MuseFrame

@Suite("Widget shared artwork")
struct WidgetSharedDataTests {
    @Test @MainActor func deferredCommitDoesNotHintUntilExplicitlyReleasedAndOnlyOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var hints = 0
        let now = Date(timeIntervalSince1970: 1_000)
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: { hints += 1 },
            widgetReloadInterval: 0, now: { now })
        let artwork = GalleryFilterTests().artwork()
        store.update(artwork, deferWidgetReload: true)
        #expect(CurrentArtworkStorage.load(directory: directory)?.artworkID == artwork.id)
        #expect(hints == 0)
        store.flushWidgetReload()
        store.reloadFromDisk()
        #expect(hints == 0)
        store.requestDeferredWidgetReload()
        store.requestDeferredWidgetReload()
        store.flushWidgetReload()
        #expect(hints == 1)
    }

    @Test @MainActor func failedDeferredCommitNeverCreatesAWidgetRequest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var hints = 0
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: { hints += 1 }, widgetReloadInterval: 0)
        store.update(GalleryFilterTests().artwork(), thumbnailData: Data(repeating: 0, count: 2_097_153), deferWidgetReload: true)
        #expect(store.storageError != nil)
        store.requestDeferredWidgetReload()
        store.flushWidgetReload()
        #expect(hints == 0)
        #expect(CurrentArtworkStorage.load(directory: directory) == nil)
    }

    @Test @MainActor func explicitScheduleHintLeavesArtworkUnchanged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var hints = 0
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: { hints += 1 }, widgetReloadInterval: 0)
        store.update(GalleryFilterTests().artwork())
        let previous = CurrentArtworkStorage.load(directory: directory)
        store.requestWidgetReload()
        #expect(hints == 2)
        #expect(CurrentArtworkStorage.load(directory: directory) == previous)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func imageFile(in directory: URL) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 1800, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1800, height: 900))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent("source.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func phaseOneSnapshotDecodesWithoutLosingMetadata() throws {
        let data = Data(#"{"artworkID":"met-437430","title":"向日葵","artist":"文森特·梵高","dateDisplay":"1887","updatedAt":1000}"#.utf8)
        let snapshot = try JSONDecoder().decode(CurrentArtworkSnapshot.self, from: data)
        #expect(snapshot.artworkID == "met-437430")
        #expect(snapshot.title == "向日葵")
        #expect(!snapshot.isSaved)
        #expect(snapshot.displayIDs.isEmpty)
        #expect(snapshot.thumbnailFileName == nil)
        #expect(snapshot.artwork == nil)
        #expect(snapshot.deepLink?.absoluteString == "museframe://artwork/met-437430")
        #expect(try JSONDecoder().decode(CurrentArtworkSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func thumbnailIsLocalBoundedJPEGAndRejectsRemoteInput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try imageFile(in: directory)
        let data = try #require(await CurrentArtworkStorage.thumbnailData(from: source))
        let decoded = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
        #expect(image.width == 640)
        #expect(image.height == 320)
        #expect(data.count < 2_097_152)
        let remote = await CurrentArtworkStorage.thumbnailData(from: URL(string: "https://example.com/never-requested.jpg")!)
        #expect(remote == nil)
    }

    @Test @MainActor func currentWorkAndSavedStateSurviveReloadTogether() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try #require(await CurrentArtworkStorage.thumbnailData(from: imageFile(in: directory)))
        let artwork = GalleryFilterTests().artwork()
        var reloads = 0
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: { reloads += 1 }, widgetReloadInterval: 0)
        store.update(artwork, isSaved: true, thumbnailData: data,
            displayIDs: ["retina", "external"], displayMode: "fit")
        let original = try #require(store.snapshot)
        #expect(store.storageError == nil)
        #expect(reloads == 1)
        let loaded = try #require(CurrentArtworkStorage.load(directory: directory))
        #expect(loaded == original)
        #expect(loaded.artwork == artwork)
        #expect(loaded.isSaved)
        #expect(loaded.displayIDs == ["retina", "external"])
        #expect(loaded.displayMode == "fit")
        #expect(loaded.shortGuide == "落日倒映水中。")
        let thumbnail = try #require(CurrentArtworkStorage.thumbnailURL(for: loaded, directory: directory))
        #expect(try Data(contentsOf: thumbnail) == data)

        store.setSaved(artworkID: "met-unrelated", isSaved: false)
        store.setSaved(artworkID: artwork.id, isSaved: true)
        #expect(reloads == 1)
        store.setSaved(artworkID: artwork.id, isSaved: false)
        #expect(reloads == 2)
        let restored = CurrentArtworkStore(directory: directory, reloadTimelines: {})
        #expect(restored.snapshot?.isSaved == false)
        #expect(restored.snapshot?.artwork == artwork)
        #expect(restored.snapshot?.updatedAt == original.updatedAt)
        #expect(restored.snapshot?.thumbnailFileName == original.thumbnailFileName)
        #expect(try Data(contentsOf: thumbnail) == data)
    }

    @Test func rejectedImageCannotReplaceExistingManifest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = CurrentArtworkSnapshot(artworkID: "met-existing", title: "Existing", artist: "Artist",
            dateDisplay: nil, summary30s: nil, thumbnailURL: nil, updatedAt: .now)
        try CurrentArtworkStorage.save(existing, directory: directory)
        let next = CurrentArtworkSnapshot(artworkID: "met-next", title: "Next", artist: "Artist",
            dateDisplay: nil, summary30s: nil, thumbnailURL: nil, updatedAt: .now,
            thumbnailFileName: "../../outside.jpg")
        #expect(CurrentArtworkStorage.thumbnailURL(for: next, directory: directory) == nil)
        #expect(throws: CocoaError.self) {
            try CurrentArtworkStorage.save(next, thumbnailData: Data([1, 2, 3]), directory: directory)
        }
        #expect(CurrentArtworkStorage.load(directory: directory) == existing)
    }

    @Test @MainActor func unpublishedGuideIsExcludedAndStorageFailureIsReported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        var reloads = 0
        let store = CurrentArtworkStore(directory: file, reloadTimelines: { reloads += 1 })
        store.update(GalleryFilterTests().artwork(status: .draft))
        #expect(store.snapshot?.summary30s == nil)
        #expect(store.storageError != nil)
        #expect(reloads == 0)
    }

    @Test @MainActor func staleGUIFavoriteCannotReplaceNewerHelperWallpaper() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = GalleryFilterTests().artwork()
        let b = Artwork(id: "met-helper", source: .met, sourceID: "helper", titleOriginal: "Helper artwork",
            artistOriginal: "Artist", dateDisplay: "1900", museumName: "Museum", sourceURL: a.sourceURL,
            image: a.image, isPublicDomain: true)
        var guiReloads = 0, helperReloads = 0
        let gui = CurrentArtworkStore(directory: directory, reloadTimelines: { guiReloads += 1 }, widgetReloadInterval: 0)
        gui.update(a)
        let helper = CurrentArtworkStore(directory: directory, reloadTimelines: { helperReloads += 1 }, widgetReloadInterval: 0)
        helper.update(b)
        #expect(gui.snapshot?.artworkID == a.id)
        gui.setSaved(artworkID: a.id, isSaved: true)
        #expect(gui.snapshot?.artworkID == b.id)
        #expect(CurrentArtworkStorage.load(directory: directory)?.artworkID == b.id)
        #expect(CurrentArtworkStorage.load(directory: directory)?.isSaved == false)
        #expect(guiReloads == 1)
        gui.setSaved(artworkID: b.id, isSaved: true)
        helper.reloadFromDisk()
        #expect(helper.snapshot?.isSaved == true)
        #expect(helperReloads == 1)
        #expect(guiReloads == 2)
        gui.reloadFromDisk()
        gui.reloadFromDisk()
        #expect(guiReloads == 2)
    }

    @Test func concurrentCommitsKeepManifestAndImmutableImageReadable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let thumbnail = try #require(await CurrentArtworkStorage.thumbnailData(from: imageFile(in: directory)))
        let imageName = CurrentArtworkStorage.thumbnailFileName(for: thumbnail)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let snapshot = CurrentArtworkSnapshot(artworkID: "met-\(index)", title: "Artwork \(index)", artist: "Artist",
                        dateDisplay: nil, summary30s: nil, thumbnailURL: nil, updatedAt: Date(timeIntervalSince1970: Double(index)),
                        thumbnailFileName: imageName)
                    try CurrentArtworkStorage.save(snapshot, thumbnailData: thumbnail, directory: directory)
                    _ = try CurrentArtworkStorage.updateSaved(artworkID: snapshot.artworkID, isSaved: true, directory: directory)
                }
            }
            try await group.waitForAll()
        }
        let loaded = try #require(CurrentArtworkStorage.load(directory: directory))
        #expect((0..<24).map { "met-\($0)" }.contains(loaded.artworkID))
        let file = try #require(CurrentArtworkStorage.thumbnailURL(for: loaded, directory: directory))
        #expect(try Data(contentsOf: file) == thumbnail)
        #expect(loaded.thumbnailFileName == imageName)
    }

    @Test @MainActor func failedWriterRetainsNewerDiskValueAndCorruptArchiveIsNotPatched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = GalleryFilterTests().artwork()
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: {}, widgetReloadInterval: 0)
        store.update(artwork)
        let newer = CurrentArtworkSnapshot(artworkID: "met-newer", title: "Newer", artist: "Artist", dateDisplay: nil,
            summary30s: nil, thumbnailURL: nil, updatedAt: .now)
        try CurrentArtworkStorage.save(newer, directory: directory)
        store.update(artwork, thumbnailData: Data(repeating: 0, count: 2_097_153))
        #expect(store.storageError != nil)
        #expect(store.snapshot == newer)
        #expect(CurrentArtworkStorage.load(directory: directory) == newer)
        let file = directory.appendingPathComponent("current-artwork.json")
        let damaged = Data("{unfinished".utf8)
        try damaged.write(to: file, options: .atomic)
        store.setSaved(artworkID: newer.artworkID, isSaved: true)
        #expect(store.storageError != nil)
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test @MainActor func rapidCommitsCoalesceWidgetRequestsAndFlushOnlyTheFinalPendingRequest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_000)
        var reloads = 0
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: { reloads += 1 },
            widgetReloadInterval: 1, now: { clock })
        let artwork = GalleryFilterTests().artwork()
        store.update(artwork)
        clock.addTimeInterval(0.1)
        store.setSaved(artworkID: artwork.id, isSaved: true)
        clock.addTimeInterval(0.1)
        store.setSaved(artworkID: artwork.id, isSaved: false)
        #expect(reloads == 1)
        #expect(CurrentArtworkStorage.load(directory: directory)?.isSaved == false)
        store.reloadFromDisk()
        #expect(reloads == 1)
        store.flushWidgetReload()
        #expect(reloads == 2)
        store.flushWidgetReload()
        #expect(reloads == 2)
        clock.addTimeInterval(2)
        store.setSaved(artworkID: artwork.id, isSaved: true)
        #expect(reloads == 3)
    }

    @Test func widgetReloadPolicyBoundsDelaysWhenTheClockMovesBackwards() {
        var policy = WidgetReloadPolicy(minimumInterval: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(policy.delay(at: start) == 0)
        policy.recordRequest(at: start)
        #expect(abs(policy.delay(at: start.addingTimeInterval(0.2)) - 0.8) < 0.001)
        #expect(policy.delay(at: start.addingTimeInterval(2)) == 0)
        #expect(policy.delay(at: start.addingTimeInterval(-3_600)) == 1)
    }

    @Test @MainActor func trailingWidgetRefreshOccursWithoutAnotherWriteOrExplicitFlush() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_000)
        var reloads = 0
        let store = CurrentArtworkStore(directory: directory, reloadTimelines: { reloads += 1 },
            widgetReloadInterval: 0.01, now: { clock })
        let artwork = GalleryFilterTests().artwork()
        store.update(artwork)
        clock.addTimeInterval(0.005)
        store.setSaved(artworkID: artwork.id, isSaved: true)
        store.setSaved(artworkID: artwork.id, isSaved: false)
        #expect(reloads == 1)
        clock.addTimeInterval(0.1)
        for _ in 0..<40 where reloads < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reloads == 2)
        #expect(CurrentArtworkStorage.load(directory: directory)?.isSaved == false)
    }
}
