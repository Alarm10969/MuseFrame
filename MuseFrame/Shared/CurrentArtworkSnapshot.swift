import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// A versioned, immutable value shared with WidgetKit, independent of SwiftData.
struct CurrentArtworkSnapshot: Codable, Sendable, Equatable {
    let artworkID: String
    let title: String
    let artist: String
    let dateDisplay: String?
    let summary30s: String?
    let thumbnailURL: URL?
    let updatedAt: Date
    let isSaved: Bool
    let thumbnailFileName: String?
    /// The app can restore the current work offline even after its gallery page changes.
    let artworkData: Data?
    let displayIDs: [String]
    let displayMode: String?

    init(artworkID: String, title: String, artist: String, dateDisplay: String?,
         summary30s: String?, thumbnailURL: URL?, updatedAt: Date,
         isSaved: Bool = false, thumbnailFileName: String? = nil,
         artworkData: Data? = nil, displayIDs: [String] = [], displayMode: String? = nil) {
        self.artworkID = artworkID
        self.title = title
        self.artist = artist
        self.dateDisplay = dateDisplay
        self.summary30s = summary30s
        self.thumbnailURL = thumbnailURL
        self.updatedAt = updatedAt
        self.isSaved = isSaved
        self.thumbnailFileName = thumbnailFileName
        self.artworkData = artworkData
        self.displayIDs = displayIDs
        self.displayMode = displayMode
    }

    private enum CodingKeys: String, CodingKey {
        case artworkID, title, artist, dateDisplay, summary30s, thumbnailURL, updatedAt
        case isSaved, thumbnailFileName, artworkData, displayIDs, displayMode
    }

    /// Phase 1 metadata remains readable after the update; no migration wipes the current work.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        artworkID = try values.decode(String.self, forKey: .artworkID)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decode(String.self, forKey: .artist)
        dateDisplay = try values.decodeIfPresent(String.self, forKey: .dateDisplay)
        summary30s = try values.decodeIfPresent(String.self, forKey: .summary30s)
        thumbnailURL = try values.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        isSaved = try values.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        thumbnailFileName = try values.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        artworkData = try values.decodeIfPresent(Data.self, forKey: .artworkData)
        displayIDs = try values.decodeIfPresent([String].self, forKey: .displayIDs) ?? []
        displayMode = try values.decodeIfPresent(String.self, forKey: .displayMode)
    }

    var deepLink: URL? {
        MuseFrameDeepLink.artwork(artworkID).url
    }

    var shortGuide: String? {
        guard let text = summary30s?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let end = text.firstIndex(where: { "。！？".contains($0) }) {
            return String(text[...end])
        }
        return text
    }

    func settingSaved(_ saved: Bool) -> CurrentArtworkSnapshot {
        CurrentArtworkSnapshot(artworkID: artworkID, title: title, artist: artist, dateDisplay: dateDisplay,
            summary30s: summary30s, thumbnailURL: thumbnailURL, updatedAt: updatedAt, isSaved: saved,
            thumbnailFileName: thumbnailFileName, artworkData: artworkData, displayIDs: displayIDs, displayMode: displayMode)
    }
}

enum CurrentArtworkStorage {
    static let appGroupIdentifier = MuseFrameSharedPaths.appGroupIdentifier
    static let widgetKind = "MuseFrameCurrentArtwork"
    private static let fileName = "current-artwork.json"
    private static let imageDirectoryName = "WidgetThumbnails"
    private static let maximumThumbnailBytes = 2_097_152

    /// GUI, helper and Widget all use the same signed group or explicit local-build root.
    static var directory: URL? { MuseFrameSharedPaths.root }

    static func load(directory override: URL? = nil) -> CurrentArtworkSnapshot? {
        try? read(directory: override)
    }

    static func read(directory override: URL? = nil) throws -> CurrentArtworkSnapshot? {
        guard let directory = override ?? directory else { throw SharedStateError.unavailableContainer }
        return try readExisting(in: directory)
    }

    @discardableResult
    static func save(_ snapshot: CurrentArtworkSnapshot, thumbnailData: Data? = nil,
                     directory override: URL? = nil) throws -> Bool {
        let changed = try transaction(directory: override) { directory in
            try write(snapshot, thumbnailData: thumbnailData, in: directory)
        }
        if changed { notifyChange(directory: override) }
        return changed
    }

    /// The ID check happens after acquiring the lock and reading the latest manifest.
    /// A GUI holding A cannot overwrite the helper's newer B when A is collected.
    static func updateSaved(artworkID: String, isSaved: Bool, directory override: URL? = nil) throws
        -> (snapshot: CurrentArtworkSnapshot?, changed: Bool) {
        let result = try transaction(directory: override) { directory in
            guard let latest = try readExisting(in: directory) else { return (snapshot: Optional<CurrentArtworkSnapshot>.none, changed: false) }
            guard latest.artworkID == artworkID, latest.isSaved != isSaved else { return (snapshot: Optional(latest), changed: false) }
            let next = latest.settingSaved(isSaved)
            let changed = try write(next, thumbnailData: nil, in: directory)
            return (snapshot: Optional(next), changed: changed)
        }
        if result.changed { notifyChange(directory: override) }
        return result
    }

    private static func notifyChange(directory override: URL?) {
        // Isolated test stores never broadcast changes to a running user's application.
        guard let target = override ?? directory, let root = MuseFrameSharedPaths.root,
              target.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { return }
        MuseFrameSharedPaths.notifyChange()
    }

    private static func transaction<T>(directory override: URL?, _ body: (URL) throws -> T) throws -> T {
        guard let directory = override ?? directory else { throw SharedStateError.unavailableContainer }
        return try ProcessFileLock.withLock(at: directory.appendingPathComponent("current-artwork.lock")) {
            try body(directory)
        }
    }

    private static func readExisting(in directory: URL) throws -> CurrentArtworkSnapshot? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(CurrentArtworkSnapshot.self, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func write(_ snapshot: CurrentArtworkSnapshot, thumbnailData: Data?, in directory: URL) throws -> Bool {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var imageChanged = false
        if let thumbnailData {
            guard thumbnailData.count <= maximumThumbnailBytes,
                  snapshot.thumbnailFileName == thumbnailFileName(for: thumbnailData),
                  let imageURL = thumbnailURL(for: snapshot, directory: directory) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try manager.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: imageURL.path) {
                // The image is immutable and ready before the atomically replaced manifest refers to it.
                try thumbnailData.write(to: imageURL, options: .atomic)
                imageChanged = true
            }
        }
        guard (try? readExisting(in: directory)) != snapshot || imageChanged else { return false }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        trimThumbnails(in: directory, protecting: snapshot.thumbnailFileName)
        return true
    }

    static func thumbnailURL(for snapshot: CurrentArtworkSnapshot, directory override: URL? = nil) -> URL? {
        guard let name = snapshot.thumbnailFileName, isSafeThumbnailFileName(name),
              let directory = override ?? directory else { return nil }
        return directory.appendingPathComponent(imageDirectoryName, isDirectory: true).appendingPathComponent(name)
    }

    static func thumbnailFileName(for data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "current-\(digest).jpg"
    }

    /// Bounded JPEG prepared from an already local image. WidgetKit performs no museum requests.
    static func thumbnailData(from localURL: URL) async -> Data? {
        guard localURL.isFileURL else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(localURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            guard CGImageDestinationFinalize(destination), data.length <= maximumThumbnailBytes else { return nil }
            return data as Data
        }.value
    }

    private static func isSafeThumbnailFileName(_ name: String) -> Bool {
        guard name.hasPrefix("current-"), name.hasSuffix(".jpg") else { return false }
        let digest = name.dropFirst("current-".count).dropLast(".jpg".count)
        return digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func trimThumbnails(in directory: URL, protecting currentName: String?) {
        let target = directory.appendingPathComponent(imageDirectoryName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: target,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        // Preserve recent entries if WidgetKit is still rendering a previous timeline.
        let dated = files.filter { isSafeThumbnailFileName($0.lastPathComponent) }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in dated.dropFirst(8) where file.lastPathComponent != currentName {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

#if !MUSEFRAME_WIDGET
import Observation

extension CurrentArtworkSnapshot {
    var artwork: Artwork? {
        guard let artworkData, let artwork = try? JSONDecoder().decode(Artwork.self, from: artworkData),
              artwork.id == artworkID else { return nil }
        return artwork
    }
}

@MainActor @Observable
final class CurrentArtworkStore {
    static let shared = CurrentArtworkStore()
    private(set) var snapshot: CurrentArtworkSnapshot?
    private(set) var storageError: String?
    @ObservationIgnored private let storageDirectory: URL?
    @ObservationIgnored private let reloadCoalescer: WidgetReloadCoalescer
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var hasDeferredWidgetReload = false

    init(directory: URL? = nil, reloadTimelines: @escaping @MainActor () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: CurrentArtworkStorage.widgetKind)
    }, widgetReloadInterval: TimeInterval = 1, now: @escaping @MainActor () -> Date = { .now }) {
        storageDirectory = directory
        self.now = now
        reloadCoalescer = WidgetReloadCoalescer(minimumInterval: widgetReloadInterval, now: now, reload: reloadTimelines)
        do { snapshot = try CurrentArtworkStorage.read(directory: directory) }
        catch { storageError = error.localizedDescription }
    }

    /// Call only after WallpaperEngine successfully changes the desktop image.
    func update(_ artwork: Artwork, isSaved: Bool = false, thumbnailData: Data? = nil,
                displayIDs: [String] = [], displayMode: String? = nil, deferWidgetReload: Bool = false) {
        let next = CurrentArtworkSnapshot(
            artworkID: artwork.id, title: artwork.displayTitle, artist: artwork.displayArtist,
            dateDisplay: artwork.dateDisplay,
            summary30s: artwork.hasPublishedGuide ? artwork.guide?.summary30s : nil,
            thumbnailURL: artwork.image.thumbnailURL, updatedAt: now(), isSaved: isSaved,
            thumbnailFileName: thumbnailData.map(CurrentArtworkStorage.thumbnailFileName(for:)),
            artworkData: try? JSONEncoder().encode(artwork), displayIDs: displayIDs, displayMode: displayMode
        )
        persist(next, thumbnailData: thumbnailData, deferWidgetReload: deferWidgetReload)
    }

    /// Collection changes affect the current work's shared state without changing wallpaper history.
    func setSaved(artworkID: String, isSaved: Bool) {
        do {
            let result = try CurrentArtworkStorage.updateSaved(artworkID: artworkID, isSaved: isSaved, directory: storageDirectory)
            snapshot = result.snapshot
            storageError = nil
            if result.changed { reloadCoalescer.request() }
        } catch {
            if let latest = CurrentArtworkStorage.load(directory: storageDirectory) { snapshot = latest }
            storageError = error.localizedDescription
        }
    }

    /// External writers invalidate this process's observation cache, without another widget request.
    func reloadFromDisk() {
        do {
            let latest = try CurrentArtworkStorage.read(directory: storageDirectory)
            if snapshot != latest { snapshot = latest }
            storageError = nil
        } catch { storageError = error.localizedDescription }
    }

    func flushWidgetReload() { reloadCoalescer.flush() }

    /// An explicit GUI settings change may invalidate the Widget's schedule without a DTO write.
    func requestWidgetReload() { reloadCoalescer.request() }

    /// The helper calls this only after its successful artwork and rotation-state commits.
    /// Flushing or repeatedly checking due work cannot release an unconfirmed request.
    func requestDeferredWidgetReload() {
        guard hasDeferredWidgetReload, storageError == nil else { return }
        hasDeferredWidgetReload = false
        requestWidgetReload()
    }

    private func persist(_ next: CurrentArtworkSnapshot, thumbnailData: Data? = nil, deferWidgetReload: Bool = false) {
        do {
            let changed = try CurrentArtworkStorage.save(next, thumbnailData: thumbnailData, directory: storageDirectory)
            snapshot = next
            storageError = nil
            if changed {
                hasDeferredWidgetReload = deferWidgetReload
                if !deferWidgetReload { requestWidgetReload() }
            }
        } catch {
            hasDeferredWidgetReload = false
            snapshot = CurrentArtworkStorage.load(directory: storageDirectory) ?? next
            storageError = error.localizedDescription
        }
    }
}
#endif
