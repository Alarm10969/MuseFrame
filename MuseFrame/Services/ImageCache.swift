import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImagePurpose: String, Sendable {
    case thumbnail
    case detail
    case wallpaper

    fileprivate var maximumPixelSize: Int? {
        switch self {
        case .thumbnail: 640
        case .detail: 2_000
        case .wallpaper: nil
        }
    }
}

enum ImageCacheError: LocalizedError, Sendable {
    case unsupportedURL
    case badResponse(Int)
    case invalidImage
    case imageTooLarge
    case clearing

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: "图片地址无效。"
        case .badResponse(let status): "图片暂时无法下载（\(status)）。"
        case .invalidImage: "无法读取这幅作品的图片。"
        case .imageTooLarge: "图片文件超过缓存允许的大小。"
        case .clearing: "图片缓存正在清理，请稍后重试。"
        }
    }
}

/// CGImage is immutable after creation; sharing it doesn't share mutable AppKit state.
struct DecodedArtworkImage: @unchecked Sendable {
    let image: CGImage
}

private final class DecodedImageBox {
    let value: DecodedArtworkImage
    init(_ value: DecodedArtworkImage) { self.value = value }
}

/// Bounded decoded memory cache plus separately sized thumbnail/detail/original disk tiers.
actor ImageCache {
    static let shared = ImageCache()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    private struct Pending {
        let task: Task<URL, Error>
        var waiters: Set<UUID>
    }

    private struct PendingDecode {
        let task: Task<DecodedArtworkImage, Error>
        var waiters: Set<UUID>
    }

    private let directory: URL
    private let legacyDirectory: URL?
    private let limitBytes: Int64
    private let memoryLimitBytes: Int
    private let decoded = NSCache<NSString, DecodedImageBox>()
    private var pending: [String: Pending] = [:]
    private var pendingDecodes: [String: PendingDecode] = [:]
    private var memoryGeneration: UInt = 0
    private var isClearing = false

    init(directory: URL? = nil, legacyDirectory: URL? = nil, limitBytes: Int64 = 1_073_741_824,
         memoryLimitBytes: Int = 100_663_296, memoryCountLimit: Int = 100) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let privateDirectory = base.appendingPathComponent("MuseFrame/Images", isDirectory: true)
        let selectedDirectory = directory ?? MuseFrameSharedPaths.root?.appendingPathComponent("Images", isDirectory: true) ?? privateDirectory
        self.directory = selectedDirectory
        #if MUSEFRAME_HELPER
        // A background service must not depend on the GUI's private sandbox container.
        self.legacyDirectory = nil
        #else
        let legacy = legacyDirectory ?? (directory == nil ? privateDirectory : nil)
        self.legacyDirectory = legacy?.resolvingSymlinksInPath().path == selectedDirectory.resolvingSymlinksInPath().path ? nil : legacy
        #endif
        self.limitBytes = max(1_048_576, limitBytes)
        self.memoryLimitBytes = max(0, memoryLimitBytes)
        decoded.totalCostLimit = max(0, memoryLimitBytes)
        decoded.countLimit = max(1, memoryCountLimit)
    }

    /// An offline-only lookup. It never starts a task or substitutes a thumbnail for an original.
    func cachedFileURL(for artwork: Artwork, purpose: ImagePurpose) -> URL? {
        guard !isClearing, !Task.isCancelled else { return nil }
        if purpose == .thumbnail, let bundled = bundledThumbnail(for: artwork) { return bundled }
        let source = sourceURL(for: artwork, purpose: purpose)
        guard source.isFileURL || source.scheme?.lowercased() == "https" else { return nil }
        let output = cacheURL(key: Self.cacheKey(url: source, purpose: purpose), source: source, purpose: purpose)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return try? migrateLegacyFile(to: output, purpose: purpose)
    }

    func fileURL(for artwork: Artwork, purpose: ImagePurpose) async throws -> URL {
        try Task.checkCancellation()
        guard !isClearing else { throw ImageCacheError.clearing }
        if purpose == .thumbnail, let bundled = bundledThumbnail(for: artwork) {
            return bundled
        }

        let source = sourceURL(for: artwork, purpose: purpose)
        guard source.isFileURL || source.scheme?.lowercased() == "https" else {
            throw ImageCacheError.unsupportedURL
        }
        let key = Self.cacheKey(url: source, purpose: purpose)
        let output = cacheURL(key: key, source: source, purpose: purpose)
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
            return output
        }
        do {
            if let migrated = try migrateLegacyFile(to: output, purpose: purpose) { return migrated }
        } catch is CancellationError { throw CancellationError() }
        catch { /* An unreadable old cache must not prevent a fresh request. */ }

        let waiter = UUID()
        let task: Task<URL, Error>
        if var existing = pending[key] {
            existing.waiters.insert(waiter)
            pending[key] = existing
            task = existing.task
        } else {
            task = Task.detached(priority: purpose == .wallpaper ? .userInitiated : .utility) {
                try await Self.download(source: source, output: output, purpose: purpose)
            }
            pending[key] = Pending(task: task, waiters: [waiter])
        }

        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                finishWaiting(key: key, waiter: waiter, cancel: false)
                try Task.checkCancellation()
                guard !isClearing else { throw ImageCacheError.clearing }
                trimDiskCache(protecting: result)
                return result
            } catch {
                finishWaiting(key: key, waiter: waiter, cancel: false)
                if Task.isCancelled { throw CancellationError() }
                // A bundled seed remains useful while offline, including in the detail sheet.
                if purpose == .detail, !(error is CancellationError),
                   let bundled = bundledThumbnail(for: artwork) {
                    return bundled
                }
                throw error
            }
        } onCancel: {
            Task { await self.finishWaiting(key: key, waiter: waiter, cancel: true) }
        }
    }

    /// Pixel sizes are computed by the view from its actual point size and backing scale.
    /// Decoding happens away from the main actor; callers share a decoded bitmap when possible.
    func decodedImage(for artwork: Artwork, purpose: ImagePurpose, maxPixelSize: Int) async throws -> DecodedArtworkImage {
        try Task.checkCancellation()
        guard !isClearing else { throw ImageCacheError.clearing }
        let maximum = min(purpose == .thumbnail ? 1_280 : 2_000, max(1, maxPixelSize))
        let generation = memoryGeneration
        let original = artwork.image.originalURL
        let applied = MuseFrameSharedPaths.root.flatMap {
            WallpaperEngine.retainedOriginal(original, in: $0.appendingPathComponent("AppliedWallpapers"))
        }
        let source = applied ?? sourceURL(for: artwork, purpose: purpose)
        guard source.isFileURL || source.scheme == "https" else { throw ImageCacheError.unsupportedURL }
        let key = "\(generation):\(purpose.rawValue):\(source.absoluteString):\(maximum)"
        if let value = decoded.object(forKey: key as NSString) {
            markDecodeReady(value.value.image, purpose: purpose, maximumPixelSize: maximum, artworkID: artwork.id)
            return value.value
        }

        let waiter = UUID()
        let task: Task<DecodedArtworkImage, Error>
        if var existing = pendingDecodes[key] {
            existing.waiters.insert(waiter)
            pendingDecodes[key] = existing
            task = existing.task
        } else {
            task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let image = try await Self.preview(from: source, maximum: maximum)
                try Task.checkCancellation()
                return DecodedArtworkImage(image: image)
            }
            pendingDecodes[key] = PendingDecode(task: task, waiters: [waiter])
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                finishDecoding(key: key, waiter: waiter, cancel: false)
                try Task.checkCancellation()
                guard !isClearing else { throw ImageCacheError.clearing }
                let cost = result.image.bytesPerRow * result.image.height
                if generation == memoryGeneration, cost <= memoryLimitBytes, memoryLimitBytes > 0 {
                    decoded.setObject(DecodedImageBox(result), forKey: key as NSString, cost: cost)
                }
                markDecodeReady(result.image, purpose: purpose, maximumPixelSize: maximum, artworkID: artwork.id)
                return result
            } catch {
                finishDecoding(key: key, waiter: waiter, cancel: false)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await self.finishDecoding(key: key, waiter: waiter, cancel: true) }
        }
    }

    /// Memory-pressure handling leaves offline files available. In-flight work won't repopulate it.
    func clearMemoryCache() {
        memoryGeneration &+= 1
        decoded.removeAllObjects()
    }

    func clear() async throws {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        clearMemoryCache()
        let tasks = pending.values.map(\.task)
        let decodeTasks = pendingDecodes.values.map(\.task)
        pending.removeAll()
        pendingDecodes.removeAll()
        tasks.forEach { $0.cancel() }
        decodeTasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
        for task in decodeTasks { _ = try? await task.value }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        if let legacyDirectory, FileManager.default.fileExists(atPath: legacyDirectory.path) {
            try FileManager.default.removeItem(at: legacyDirectory)
        }
    }

    private func markDecodeReady(_ image: CGImage, purpose: ImagePurpose, maximumPixelSize: Int, artworkID: String) {
        let event: String
        switch purpose {
        case .thumbnail: event = "first-thumbnail-decoded-ready"
        case .detail: event = "first-detail-decoded-ready"
        case .wallpaper: return
        }
        let fields = [
            "pixelWidth": String(image.width), "pixelHeight": String(image.height),
            "maximumPixelSize": String(maximumPixelSize), "artworkID": artworkID
        ]
        PerformanceDiagnostics.mark(event, once: true, fields: fields)
        if purpose == .detail { PerformanceDiagnostics.mark("detail-decoded-ready", fields: fields) }
    }

    /// Copy one requested legacy cache file, validate it, then publish atomically.
    /// The source remains available if cancellation, copying or validation fails.
    private func migrateLegacyFile(to output: URL, purpose: ImagePurpose) throws -> URL? {
        guard let legacyDirectory else { return nil }
        try Task.checkCancellation()
        let manager = FileManager.default
        let source = legacyDirectory.appendingPathComponent(purpose.rawValue, isDirectory: true)
            .appendingPathComponent(output.lastPathComponent)
        guard manager.fileExists(atPath: source.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= 125_829_120,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw ImageCacheError.invalidImage }
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        try Task.checkCancellation()
        let copiedSize = try manager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard copiedSize?.int64Value == size.int64Value,
              let image = CGImageSourceCreateWithURL(temporary as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatus(image) == .statusComplete,
              Self.thumbnail(from: temporary, maxPixelSize: 32) != nil else { throw ImageCacheError.invalidImage }
        try Task.checkCancellation()
        try Self.publishCacheFile(temporary, to: output)
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
        trimDiskCache(protecting: output)
        PerformanceDiagnostics.mark("legacy-cache-file-migrated", fields: [
            "purpose": purpose.rawValue, "bytes": size.stringValue
        ])
        return output
    }

    private func sourceURL(for artwork: Artwork, purpose: ImagePurpose) -> URL {
        switch purpose {
        case .thumbnail: return artwork.image.thumbnailURL
        case .detail:
            if artwork.image.detailURL == artwork.image.originalURL, artwork.source == .met {
                return artwork.image.thumbnailURL
            }
            return artwork.image.detailURL ?? artwork.image.thumbnailURL
        case .wallpaper: return artwork.image.originalURL
        }
    }

    private func bundledThumbnail(for artwork: Artwork) -> URL? {
        guard artwork.image.bundledThumbnailSourceURL == nil || artwork.image.bundledThumbnailSourceURL == artwork.image.originalURL else {
            return nil
        }
        return MuseFrameResources.bundle.url(forResource: artwork.id, withExtension: "jpg")
    }

    private static func preview(from url: URL, maximum: Int) async throws -> CGImage {
        let imageSource: CGImageSource?
        if url.isFileURL {
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            var request = URLRequest(url: url)
            request.setValue("MuseFrame/0.5 (macOS artwork browser)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ImageCacheError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            guard bytes.count <= 125_829_120 else { throw ImageCacheError.imageTooLarge }
            imageSource = CGImageSourceCreateWithData(bytes as CFData, nil)
        }
        guard let imageSource, let image = thumbnail(source: imageSource, maxPixelSize: maximum) else {
            throw ImageCacheError.invalidImage
        }
        return image
    }

    /// Older releases cached browse-only JPEGs. Applied desktops live in a separate directory.
    func removeLegacyPreviews(artworks: [Artwork], appliedDirectory: URL) throws {
        for root in [directory, legacyDirectory].compactMap({ $0 }) {
            for purpose in [ImagePurpose.thumbnail, .detail] {
                let folder = root.appendingPathComponent(purpose.rawValue)
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            }
            let originals = root.appendingPathComponent("wallpaper")
            guard FileManager.default.fileExists(atPath: originals.path) else { continue }
            for work in artworks {
                let source = work.image.originalURL
                let key = Self.cacheKey(url: source, purpose: .wallpaper)
                let candidate = originals.appendingPathComponent(key).appendingPathExtension(
                    cacheURL(key: key, source: source, purpose: .wallpaper).pathExtension)
                guard FileManager.default.fileExists(atPath: candidate.path),
                      let retained = WallpaperEngine.retainedOriginal(source, in: appliedDirectory),
                      FileManager.default.contentsEqual(atPath: retained.path, andPath: candidate.path) else { continue }
                try FileManager.default.removeItem(at: candidate)
            }
        }
    }

    static func stageWallpaper(_ source: URL, in temporaryDirectory: URL) async throws -> URL {
        guard source.isFileURL || source.scheme == "https" else { throw ImageCacheError.unsupportedURL }
        let suffix = ["jpeg","jpg","png","tiff","tif","heic","webp"].contains(source.pathExtension.lowercased())
            ? source.pathExtension.lowercased() : "jpg"
        let output = temporaryDirectory.appendingPathComponent("original").appendingPathExtension(suffix)
        return try await download(source: source, output: output, purpose: .wallpaper)
    }

    private func finishDecoding(key: String, waiter: UUID, cancel: Bool) {
        guard var request = pendingDecodes[key], request.waiters.remove(waiter) != nil else { return }
        if request.waiters.isEmpty {
            if cancel { request.task.cancel() }
            pendingDecodes.removeValue(forKey: key)
        } else {
            pendingDecodes[key] = request
        }
    }

    nonisolated static func thumbnail(from url: URL, maxPixelSize: Int = 640) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func finishWaiting(key: String, waiter: UUID, cancel: Bool) {
        guard var request = pending[key], request.waiters.remove(waiter) != nil else { return }
        if request.waiters.isEmpty {
            if cancel { request.task.cancel() }
            pending.removeValue(forKey: key)
        } else {
            pending[key] = request
        }
    }

    private func cacheURL(key: String, source: URL, purpose: ImagePurpose) -> URL {
        let originalExtension = source.pathExtension.lowercased()
        let allowed = ["jpeg", "jpg", "png", "heic", "tiff", "tif", "webp"]
        let suffix = purpose == .wallpaper && allowed.contains(originalExtension) ? originalExtension : "jpg"
        return directory.appendingPathComponent(purpose.rawValue, isDirectory: true)
            .appendingPathComponent(key).appendingPathExtension(suffix)
    }

    nonisolated private static func cacheKey(url: URL, purpose: ImagePurpose) -> String {
        SHA256.hash(data: Data((purpose.rawValue + ":" + url.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func download(source: URL, output: URL, purpose: ImagePurpose) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let downloaded: URL
        if source.isFileURL {
            downloaded = source
        } else {
            var request = URLRequest(url: source)
            request.timeoutInterval = 45
            request.setValue("MuseFrame/0.2 (macOS artwork browser)", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await session.download(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                try? manager.removeItem(at: file)
                throw ImageCacheError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            downloaded = file
        }
        defer {
            if !source.isFileURL { try? manager.removeItem(at: downloaded) }
        }
        try Task.checkCancellation()
        let attributes = try manager.attributesOfItem(atPath: downloaded.path)
        guard let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value <= 125_829_120 else { throw ImageCacheError.imageTooLarge }
        guard let imageSource = CGImageSourceCreateWithURL(downloaded as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0 else { throw ImageCacheError.invalidImage }

        let temporary = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? manager.removeItem(at: temporary) }
        if let maximum = purpose.maximumPixelSize {
            guard let image = thumbnail(from: downloaded, maxPixelSize: maximum),
                  let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ImageCacheError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageCacheError.invalidImage }
        } else {
            try manager.copyItem(at: downloaded, to: temporary)
        }
        try Task.checkCancellation()
        try publishCacheFile(temporary, to: output)
        return output
    }

    /// Another process may finish the same immutable cache entry first.
    /// Never remove its already published file while a wallpaper reader is using it.
    nonisolated private static func publishCacheFile(_ temporary: URL, to output: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: output.path) else { return }
        do { try manager.moveItem(at: temporary, to: output) }
        catch {
            if !manager.fileExists(atPath: output.path) { throw error }
        }
    }

    private func trimDiskCache(protecting current: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard url.pathExtension != "partial",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limitBytes else { return }
        // Leave headroom rather than scanning the disk for each subsequent image.
        let target = limitBytes * 9 / 10
        // A single valid original can exceed a user-supplied limit; do not return a deleted file.
        // Individual downloads still have a hard 120 MiB limit.
        let protectedPath = current.resolvingSymlinksInPath().path
        for entry in entries.sorted(by: { $0.date < $1.date })
            where total > target && entry.url.resolvingSymlinksInPath().path != protectedPath {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }
}
