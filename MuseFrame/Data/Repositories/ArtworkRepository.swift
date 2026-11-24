import Foundation

struct CatalogSyncResult: Sendable {
    let artworks: [Artwork]
    let invalidatedIDs: Set<String>
    let warnings: [String]
}

/// Museum metadata has a versioned local catalog. SwiftData remains the independent user-state store.
actor ArtworkRepository {
    private let sources: [any ArtworkSourceProtocol]
    private let directory: URL
    private let seedURL: URL?
    private let syncInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var seedSnapshot: [Artwork] = []
    private var catalog: [Artwork]?
    private var tombstones: Set<String> = []
    private var sourceStates: [String: SourceSyncState] = [:]
    private var pendingWarnings: [String] = []
    private var isSyncing = false

    init(sources: [any ArtworkSourceProtocol] = [MetMuseumSource(), CuratedCommonsSource()], directory: URL? = nil,
         seedURL: URL? = nil, syncInterval: TimeInterval = 86_400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sources = sources
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appendingPathComponent("MuseFrame/Catalog", isDirectory: true)
        self.seedURL = seedURL
        self.syncInterval = syncInterval
        self.now = now
    }

    func loadSeed() throws -> [Artwork] {
        if !seedSnapshot.isEmpty { return seedSnapshot }
        guard let url = seedURL ?? MuseFrameResources.bundle.url(forResource: "seed", withExtension: "json") else {
            throw ArtworkSourceError.missingSeed
        }
        seedSnapshot = permittedUnique(try JSONDecoder().decode([Artwork].self, from: Data(contentsOf: url)))
        return seedSnapshot
    }

    /// Bundled art is always ready offline. Cached metadata updates preserve the initial curated ordering.
    func loadCatalog() throws -> [Artwork] {
        if let catalog { return catalog }
        let seed = try loadSeed()
        var result = seed
        let file = directory.appendingPathComponent("catalog-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file))
                guard snapshot.version == 1 else { throw ArtworkSourceError.invalidCatalog }
                tombstones = snapshot.invalidatedIDs
                sourceStates = snapshot.sourceStates
                result = merge(snapshot.artworks, into: result)
            } catch {
                pendingWarnings.append("本地画作更新未能读取，已恢复内置画廊。")
                // A damaged metadata cache never prevents the bundled collection from opening.
            }
        }
        result.removeAll { tombstones.contains($0.id) }
        catalog = result
        return result
    }

    func invalidatedArtworkIDs() throws -> Set<String> {
        _ = try loadCatalog()
        return tombstones
    }

    /// Network pages also persist; relaunching does not discard discovered works or metadata updates.
    func persist(_ incoming: [Artwork]) throws {
        let existing = try loadCatalog()
        let allowed = permittedUnique(incoming)
        catalog = merge(allowed, into: existing).filter { !tombstones.contains($0.id) }
        try saveSnapshot()
    }

    /// Each run performs bounded discovery + metadata revalidation, rather than refetching hundreds of works.
    /// Only definitive missing/restricted results invalidate cached entries. Offline/transient errors retain them.
    func syncIfNeeded(force: Bool = false) async throws -> CatalogSyncResult {
        _ = try loadCatalog()
        guard !isSyncing else { return CatalogSyncResult(artworks: catalog ?? [], invalidatedIDs: tombstones, warnings: []) }
        isSyncing = true
        defer { isSyncing = false }
        var warnings = pendingWarnings
        pendingWarnings.removeAll()
        let started = now()
        for source in sources {
            try Task.checkCancellation()
            var state = sourceStates[source.source.rawValue] ?? SourceSyncState()
            let retryInterval = state.lastSuccess == state.lastAttempt ? syncInterval : min(syncInterval, 900)
            guard force || started.timeIntervalSince(state.lastAttempt ?? .distantPast) >= retryInterval else { continue }
            state.lastAttempt = started
            var succeeded = false
            do {
                let discovered = try await source.search(query: "painting", page: state.discoveryPage, pageSize: 16)
                let allowed = permittedUnique(discovered)
                catalog = merge(allowed, into: catalog ?? [])
                state.discoveryPage = discovered.isEmpty ? 1 : state.discoveryPage + 1
                succeeded = true
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { warnings.append("\(source.source.displayName)：暂时无法同步新作品。") }

            let known = (catalog ?? []).filter { $0.source == source.source }
            var refreshIDs: [String] = []
            // The Met supplies a true metadataDate feed. Its cursor and watermark survive restarts.
            do {
                if let updates = try await source.updatedArtworkIDs(since: state.watermark ?? started.addingTimeInterval(-86_400),
                                                                   offset: state.changeOffset, limit: 16) {
                    let knownIDs = Set(known.map(\.id))
                    refreshIDs = updates.ids.filter { knownIDs.contains($0) }
                    state.changeOffset += updates.ids.count
                    if !updates.hasMore { state.changeOffset = 0; state.watermark = started }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { warnings.append("\(source.source.displayName)：元数据更新暂时不可用。") }
            // Periodic revalidation also detects removal/rights changes absent from a source's change feed.
            if !known.isEmpty {
                let start = state.refreshOffset % known.count
                for offset in 0..<min(4, known.count) {
                    let id = known[(start + offset) % known.count].id
                    if !refreshIDs.contains(id) { refreshIDs.append(id) }
                }
                state.refreshOffset = (start + min(4, known.count)) % known.count
            }
            for id in refreshIDs.prefix(20) {
                try Task.checkCancellation()
                do {
                    let refreshed = try await source.fetchArtwork(id: id)
                    if source.licensePolicy(for: refreshed) {
                        catalog = merge([refreshed], into: catalog ?? [])
                    } else {
                        invalidate(id)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError where error.code == .cancelled { throw error }
                catch ArtworkSourceError.restrictedImage { invalidate(id) }
                catch ArtworkSourceError.unavailableImage { invalidate(id) }
                catch ArtworkSourceError.httpStatus(let status) where status == 404 || status == 410 { invalidate(id) }
                catch { warnings.append("\(source.source.displayName)：已保留离线元数据。") }
            }
            if succeeded { state.lastSuccess = started }
            sourceStates[source.source.rawValue] = state
            // Persist each provider separately so a later cancellation or unavailable museum loses no progress.
            try saveSnapshot()
        }
        return CatalogSyncResult(artworks: catalog ?? [], invalidatedIDs: tombstones,
                                 warnings: Array(Set(warnings)).sorted())
    }

    /// A failing museum does not discard a successful page from another source.
    func search(query: String, page: Int = 1) async throws -> [Artwork] {
        let pages = try await withThrowingTaskGroup(of: MuseumPage.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return MuseumPage(index: index, result: .success(try await source.search(query: query, page: page, pageSize: 20)))
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as URLError where error.code == .cancelled { throw error }
                    catch { return MuseumPage(index: index, result: .failure(error)) }
                }
            }
            var pages: [MuseumPage] = []
            for try await page in group { pages.append(page) }
            return pages.sorted { $0.index < $1.index }
        }
        var results: [Artwork] = []
        var firstError: (any Error)?
        for page in pages {
            switch page.result {
            case .success(let artworks): results += artworks
            case .failure(let error): if firstError == nil { firstError = error }
            }
        }
        if results.isEmpty, let firstError { throw firstError }
        let permitted = permittedUnique(results).filter { !tombstones.contains($0.id) }
        try persist(permitted)
        return permitted
    }

    func artwork(id: String) async throws -> Artwork {
        _ = try loadCatalog()
        if tombstones.contains(id) { throw ArtworkSourceError.restrictedImage }
        if let artwork = try loadCatalog().first(where: { $0.id == id }) { return artwork }
        guard let source = sources.first(where: { id.hasPrefix($0.source.rawValue + "-") }) else {
            throw ArtworkSourceError.invalidID
        }
        let artwork = try await source.fetchArtwork(id: id)
        guard source.licensePolicy(for: artwork) else { throw ArtworkSourceError.restrictedImage }
        try persist([artwork])
        return artwork
    }

    private func permittedUnique(_ artworks: [Artwork]) -> [Artwork] {
        var seen = Set<String>()
        return artworks.filter { artwork in
            !tombstones.contains(artwork.id) && seen.insert(artwork.id).inserted
                && sources.contains { $0.licensePolicy(for: artwork) }
        }
    }

    private func invalidate(_ id: String) {
        tombstones.insert(id)
        catalog?.removeAll { $0.id == id }
    }

    private func saveSnapshot() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = CatalogSnapshot(version: 1, artworks: catalog ?? [], invalidatedIDs: tombstones, sourceStates: sourceStates)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory.appendingPathComponent("catalog-v1.json"), options: .atomic)
    }

    private func merge(_ incoming: [Artwork], into current: [Artwork]) -> [Artwork] {
        var result = current
        var indices = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
        for artwork in permittedUnique(incoming) {
            if let index = indices[artwork.id] { result[index] = artwork.preservingEditorialData(from: result[index]) }
            else { indices[artwork.id] = result.count; result.append(artwork) }
        }
        return result
    }
}

private struct SourceSyncState: Codable, Sendable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var watermark: Date?
    var discoveryPage = 1
    var refreshOffset = 0
    var changeOffset = 0
}

private struct CatalogSnapshot: Codable, Sendable {
    let version: Int
    let artworks: [Artwork]
    let invalidatedIDs: Set<String>
    let sourceStates: [String: SourceSyncState]
}

private struct MuseumPage: Sendable {
    let index: Int
    let result: Result<[Artwork], any Error>
}

extension Artwork {
    /// Preserve independently curated content and measured pixels if the museum returns a partial record.
    /// Pixel measurements belong to one image URL and cannot be carried onto a replacement image.
    func preservingEditorialData(from old: Artwork) -> Artwork {
        let sameImage = image.originalURL == old.image.originalURL
        let keepResolution = sameImage && !image.hasVerifiedResolution && old.image.hasVerifiedResolution
        let mergedImage = ArtworkImage(originalURL: image.originalURL, thumbnailURL: image.thumbnailURL,
            width: keepResolution ? old.image.width : image.width, height: keepResolution ? old.image.height : image.height,
            attribution: image.attribution ?? old.image.attribution, license: image.license,
            focalRegion: image.focalRegion ?? (sameImage ? old.image.focalRegion : nil),
            detailURL: image.detailURL ?? (sameImage ? old.image.detailURL : nil),
            bundledThumbnailSourceURL: image.bundledThumbnailSourceURL ?? old.image.bundledThumbnailSourceURL,
            availableSizes: image.availableSizes ?? (sameImage ? old.image.availableSizes : nil),
            subjectBounds: image.subjectBounds ?? (sameImage ? old.image.subjectBounds : nil),
            safeCropRect: image.safeCropRect ?? (sameImage ? old.image.safeCropRect : nil),
            focalPoint: image.focalPoint ?? (sameImage ? old.image.focalPoint : nil))
        let keepMovement = old.movementZh != nil || movement == "Other" || movement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let editorialThemes = old.themes.contains { theme in
            theme.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        }
        let retainedGuide = guide ?? old.guide
        return Artwork(id: id, source: source, sourceID: sourceID, titleOriginal: titleOriginal,
            titleZh: titleZh ?? old.titleZh, artistOriginal: artistOriginal, artistZh: artistZh ?? (artistOriginal == old.artistOriginal ? old.artistZh : nil),
            dateDisplay: dateDisplay, yearStart: yearStart ?? old.yearStart,
            movement: keepMovement ? old.movement : movement, movementZh: movementZh ?? old.movementZh,
            themes: editorialThemes || themes.isEmpty ? old.themes : themes, medium: medium ?? old.medium,
            dimensions: dimensions ?? old.dimensions, museumName: museumName, sourceURL: sourceURL,
            image: mergedImage, isPublicDomain: isPublicDomain, metadataLicense: metadataLicense,
            guideStatus: retainedGuide == nil ? guideStatus : (guide == nil ? old.guideStatus : guideStatus),
            dominantColors: dominantColors.isEmpty && sameImage ? old.dominantColors : dominantColors,
            guide: retainedGuide, artistID: artistID ?? (artistOriginal == old.artistOriginal ? old.artistID : nil), yearEnd: yearEnd ?? old.yearEnd,
            metadataUpdatedAt: metadataUpdatedAt ?? old.metadataUpdatedAt)
    }
}
