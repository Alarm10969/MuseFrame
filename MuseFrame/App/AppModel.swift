import AppKit
import Observation
import SwiftData
import SwiftUI

enum GalleryTab: String, CaseIterable { case gallery = "Gallery", history = "Art History", saved = "Saved" }
enum SavedSort: String, CaseIterable { case recent = "收藏时间", artist = "艺术家", year = "年代" }

struct WallpaperRequest: Sendable {
    let artwork: Artwork
    let allScreens: Bool
    let screenID: String?
    let mode: WallpaperMode
}

private final class AppStateObservations: @unchecked Sendable {
    var values: [(NotificationCenter, NSObjectProtocol)] = []
    deinit { for (center, token) in values { center.removeObserver(token) } }
}

@MainActor @Observable final class AppModel {
    var tab = GalleryTab.gallery
    var artworks: [Artwork] = []
    var filter = GalleryFilter()
    var searchInput = ""
    var savedDates: [String: Date] = [:]
    var savedSort = SavedSort.recent
    var selectedArtwork: Artwork?
    var artHistory: ArtHistorySnapshot = .empty
    var historyFocus: ArtHistoryNodeID?
    var presentedArtist: Artist?
    var historyMagnification = 1.0
    var screens: [ScreenProfile] = []
    var notice: String?
    var wallpaperError: String?
    var isLoading = false
    var isSyncing = false
    var hasMore = true
    var isSettingWallpaper = false
    var page = 0
    var editorialStatus: String?
    private let editorialStore: EditorialStore
    private let feedAddress: () -> URL?
    private var edition: EditorialEdition?
    private var museumQuery = ""
    private var museumMatches: Set<String> = []
    private var editorialAddress: URL? {
        feedAddress()
    }
    let rotation: RotationEngine
    let currentStore: CurrentArtworkStore
    let backgroundService: BackgroundServiceController
    @ObservationIgnored let repository: ArtworkRepository
    @ObservationIgnored private let historyRepository: ArtHistoryRepository
    @ObservationIgnored var container: ModelContainer?
    @ObservationIgnored var context: ModelContext?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var savedSnapshots: [String: Artwork] = [:]
    @ObservationIgnored private var invalidatedIDs: Set<String> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var sharedRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let observations = AppStateObservations()
    @ObservationIgnored private let observesSharedState: Bool
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored var lastWallpaperRequest: WallpaperRequest?

    init(repository: ArtworkRepository = ArtworkRepository(), modelContainer: ModelContainer? = nil,
         rotation: RotationEngine? = nil, currentStore: CurrentArtworkStore? = nil, autoStart: Bool = true,
         historyRepository: ArtHistoryRepository = ArtHistoryRepository(),
         editorialStore: EditorialStore = EditorialStore(), feedAddress: (() -> URL?)? = nil) {
        self.editorialStore = editorialStore
        self.feedAddress = feedAddress ?? {
            guard autoStart, let value = UserDefaults.standard.string(forKey: "editorialFeedURL"),
                  !value.isEmpty else { return nil }
            return URL(string: value)
        }
        PerformanceDiagnostics.mark("model-init-begin", once: true)
        self.repository = repository
        self.historyRepository = historyRepository
        self.rotation = rotation ?? RotationEngine()
        self.currentStore = currentStore ?? .shared
        self.backgroundService = BackgroundServiceController(managesRegistration: autoStart)
        observesSharedState = autoStart
        do {
            let store = try modelContainer ?? ModelContainer(for: SavedArtwork.self)
            container = store
            context = ModelContext(store)
            let records = try context?.fetch(FetchDescriptor<SavedArtwork>()) ?? []
            savedDates = Dictionary(records.map { ($0.artworkID, $0.savedAt) }, uniquingKeysWith: max)
            savedSnapshots = Dictionary(records.compactMap { record in
                (try? JSONDecoder().decode(Artwork.self, from: record.snapshot)).map { (record.artworkID, $0) }
            }, uniquingKeysWith: { first, _ in first })
            artworks = Array(savedSnapshots.values).sorted { $0.id < $1.id }
        } catch { notice = "无法打开收藏资料库：\(error.localizedDescription)" }
        refreshScreens()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshScreens() }
        }
        if let screenObserver { observations.values.append((NotificationCenter.default, screenObserver)) }
        if autoStart {
            let center = DistributedNotificationCenter.default()
            let token = center.addObserver(forName: MuseFrameSharedPaths.changeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadSharedState() }
            }
            observations.values.append((center, token))
            let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadSharedState() }
            }
            observations.values.append((NotificationCenter.default, active))
        }
        if autoStart { Task { [weak self] in await self?.start() } }
    }

    deinit { startupTask?.cancel(); syncTask?.cancel(); sharedRefreshTask?.cancel() }

    var currentArtwork: Artwork? {
        guard let snapshot = currentStore.snapshot else { return nil }
        return artworks.first { $0.id == snapshot.artworkID } ?? snapshot.artwork
    }
    var visibleArtworks: [Artwork] {
        var otherFilters = filter
        otherFilters.query = ""
        var result = artworks.filter { work in
            guard tab != .saved || savedDates[work.id] != nil else { return false }
            if tab == .gallery, !museumQuery.isEmpty, filter.query == museumQuery, museumMatches.contains(work.id) {
                return otherFilters.matches(work, screens: screens)
            }
            return filter.matches(work, screens: screens)
        }
        if tab == .saved {
            switch savedSort {
            case .recent: result.sort { (savedDates[$0.id] ?? .distantPast) > (savedDates[$1.id] ?? .distantPast) }
            case .artist: result.sort { $0.displayArtist.localizedStandardCompare($1.displayArtist) == .orderedAscending }
            case .year: result.sort { ($0.yearStart ?? 0) < ($1.yearStart ?? 0) }
            }
        }
        return result
    }
    var currentDisplayID: String? {
        WallpaperEngine.identifier(of: NSApp?.keyWindow?.screen) ?? WallpaperEngine.identifier(of: NSScreen.main)
    }

    func refreshScreens() {
        screens = ScreenProfile.current()
        if let id = filter.screenID, id != "all" { filter.screenID = ScreenProfile.canonicalIdentifier(for: id, in: screens) }
        if let id = rotation.settings.screenID,
           let canonical = ScreenProfile.canonicalIdentifier(for: id, in: screens), canonical != id {
            var settings = rotation.settings; settings.screenID = canonical
            try? rotation.updateSettings(settings)
        }
    }

    func start(synchronize: Bool = true, scheduleRotation: Bool = true) async {
        if let startupTask { await startupTask.value; return }
        guard !started else { return }
        let task = Task { [weak self] in await self?.finishStart(synchronize: synchronize, publishLaunchEvent: scheduleRotation) }
        startupTask = Task { _ = await task.value }
        await startupTask?.value
        startupTask = nil
    }

    private func finishStart(synchronize: Bool, publishLaunchEvent: Bool) async {
        do {
            if let address = editorialAddress { edition = await editorialStore.cached(at: address) }
            let catalog = try await repository.loadCatalog()
            invalidatedIDs = try await repository.invalidatedArtworkIDs()
            replaceCatalog(catalog)
        }
        catch { notice = "无法读取本地画作：\(error.localizedDescription)" }
        started = true
        publishRotationLibrary()
        migrateAppliedWallpapers()
        if observesSharedState, let root = MuseFrameSharedPaths.root,
           let lease = try? ProcessFileLock.acquire(at: root.appendingPathComponent("wallpaper-apply.lock"), blocking: false) {
            try? await ImageCache.shared.removeLegacyPreviews(artworks: artworks,
                appliedDirectory: root.appendingPathComponent("AppliedWallpapers"))
            withExtendedLifetime(lease) {}
        }
        PerformanceDiagnostics.mark("catalog-ready", once: true, fields: ["count": String(artworks.count)])
        currentStore.reloadFromDisk()
        currentStore.setSaved(artworkID: currentStore.snapshot?.artworkID ?? "", isSaved: currentArtwork.map(isSaved) ?? false)
        rotation.start(candidateProvider: { [weak self] settings in self?.rotationCandidates(settings) ?? [] },
            currentArtworkID: { [weak self] in self?.currentStore.snapshot?.artworkID },
            cachedOriginal: { artwork in
                if await ImageCache.shared.cachedFileURL(for: artwork, purpose: .wallpaper) != nil { return true }
                return await MainActor.run { WallpaperEngine().existingDesktopImage(for: artwork) != nil }
            }, apply: { [weak self] artwork, settings, allowDownload in
                guard let self else { throw CancellationError() }
                let id = settings.screenID ?? self.screens.first(where: \.isMain)?.id
                let request = WallpaperRequest(artwork: artwork, allScreens: settings.allDisplays, screenID: id, mode: settings.mode)
                try await self.performWallpaper(request, allowDownload: allowDownload)
            }, scheduleAutomatically: false, publishLaunchEvent: publishLaunchEvent, observeSharedChanges: observesSharedState)
        await backgroundService.reconcile(enabled: rotation.settings.enabled)
        if observesSharedState {
            sharedRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.reloadSharedState()
                }
            }
        }
        if synchronize { syncTask = Task { [weak self] in await self?.synchronizeCatalog() } }
    }

    func reloadSharedState() {
        currentStore.reloadFromDisk()
        try? rotation.refreshFromDisk()
        backgroundService.refresh()
    }

    private func publishRotationLibrary() {
        guard started else { return }
        do { try rotation.publishLibrary(artworks: artworks.filter { !invalidatedIDs.contains($0.id) }, savedIDs: Set(savedDates.keys)) }
        catch { notice = "未能同步后台作品来源：\(error.localizedDescription)" }
    }

    private func migrateAppliedWallpapers() {
        guard let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MuseFrame/AppliedWallpapers"),
              let destination = try? MuseFrameSharedPaths.url("AppliedWallpapers"),
              source.standardizedFileURL != destination.standardizedFileURL,
              let files = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in files where file.pathExtension != "partial" {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: file, to: target) }
            }
        } catch { notice = "原壁纸文件已保留，部分资源暂未迁入共享目录。" }
    }

    func synchronizeCatalog(force: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if let address = editorialAddress {
                do {
                    let update = try await editorialStore.refresh(at: address)
                    if address == editorialAddress {
                        edition = update
                        editorialStatus = "策展目录版本 " + String(update.revision)
                        replaceCatalog(try await repository.loadCatalog())
                    }
                } catch { editorialStatus = "策展目录暂时无法更新，已保留上次内容。" }
            } else { edition = nil; editorialStatus = nil }
            let result = try await repository.syncIfNeeded(force: force)
            invalidatedIDs.formUnion(result.invalidatedIDs)
            replaceCatalog(result.artworks)
            if !result.warnings.isEmpty { notice = "部分馆藏暂时无法更新，已保留本地作品。" }
        } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
            notice = "画作暂时无法更新，已保留本地内容。"
        }
    }

    private func replaceCatalog(_ museumCatalog: [Artwork]) {
        var catalog = museumCatalog
        if let edition {
            let known = Dictionary(museumCatalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let featuredIDs = Set(edition.artworks.map(\.id))
            catalog = edition.artworks.map { work in
                known[work.id]?.preservingEditorialData(from: work) ?? work
            } + museumCatalog.filter { !featuredIDs.contains($0.id) }
        }
        let ids = Set(catalog.map(\.id))
        let restored = savedSnapshots.values.filter { !ids.contains($0.id) && !invalidatedIDs.contains($0.id) }
        artworks = catalog.filter { !invalidatedIDs.contains($0.id) } + restored.sorted { $0.id < $1.id }
        refreshArtHistory()
        publishRotationLibrary()
    }

    private func refreshArtHistory() {
        if let edition {
            artHistory = ArtHistoryRepository.decode(historyData: edition.history, guideData: edition.guides,
                artworks: artworks, invalidatedArtworkIDs: invalidatedIDs)
        } else {
            artHistory = historyRepository.load(artworks: artworks, invalidatedArtworkIDs: invalidatedIDs)
        }
        artworks = artworks.map { artHistory.applyingEditorialOverlay(to: $0) }
        if let historyFocus, !containsHistoryNode(historyFocus) { self.historyFocus = nil }
    }

    private func containsHistoryNode(_ target: ArtHistoryNodeID) -> Bool {
        switch target {
        case .artist(let id): artHistory.artist(id: id) != nil
        case .movement(let id): artHistory.movement(id: id) != nil
        case .artwork(let id): artHistory.coreArtworkIDs.contains(id) && artHistory.artwork(id: id) != nil
        }
    }

    @discardableResult
    func focusHistory(_ target: ArtHistoryNodeID) -> Bool {
        guard containsHistoryNode(target) else { return false }
        selectedArtwork = nil
        historyFocus = target
        tab = .history
        return true
    }

    func navigate(to destination: MuseFrameDeepLink) async {
        await start()
        reloadSharedState()
        switch destination {
        case .gallery: selectedArtwork = nil; tab = .gallery
        case .artwork(let id): await openArtwork(id: id)
        case .artist(let id):
            if !focusHistory(.artist(id)) { selectedArtwork = nil; historyFocus = nil; tab = .history }
        case .movement(let id):
            if !focusHistory(.movement(id)) { selectedArtwork = nil; historyFocus = nil; tab = .history }
        }
    }

    func searchMuseum(_ query: String) async {
        museumQuery = ""
        museumMatches = []
        guard tab == .gallery, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let found = try await repository.search(query: query, page: 1)
            let catalog = try await repository.loadCatalog()
            try Task.checkCancellation()
            guard searchInput == query, tab == .gallery else { return }
            museumMatches = Set(found.map(\.id))
            museumQuery = query
            replaceCatalog(catalog)
        } catch {
            if !Task.isCancelled && searchInput == query {
                notice = "馆藏搜索暂时不可用，当前显示已知作品。"
            }
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore, !filter.isActive else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await repository.search(query: "painting", page: page + 1)
            page += 1
            hasMore = !next.isEmpty
            replaceCatalog(try await repository.loadCatalog())
        } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
            notice = "博物馆暂时无法连接，已保留本地画作。"
        }
    }

    func merge(_ incoming: [Artwork]) {
        var index = Dictionary(artworks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for artwork in incoming where !invalidatedIDs.contains(artwork.id) {
            if let position = index[artwork.id] { artworks[position] = artwork.preservingEditorialData(from: artworks[position]) }
            else { index[artwork.id] = artworks.count; artworks.append(artwork) }
        }
        refreshArtHistory()
        publishRotationLibrary()
    }

    func isSaved(_ artwork: Artwork) -> Bool { savedDates[artwork.id] != nil }
    func toggleSaved(_ artwork: Artwork) {
        guard let context else { notice = "收藏资料库不可用，请重新打开 MuseFrame。"; return }
        do {
            let records = try context.fetch(FetchDescriptor<SavedArtwork>()).filter { $0.artworkID == artwork.id }
            if let existing = records.first { context.delete(existing) }
            else { context.insert(try SavedArtwork(artwork: artwork)) }
            try context.save()
            if records.isEmpty { savedDates[artwork.id] = .now; savedSnapshots[artwork.id] = artwork; merge([artwork]) }
            else { savedDates.removeValue(forKey: artwork.id); savedSnapshots.removeValue(forKey: artwork.id) }
            publishRotationLibrary()
            currentStore.setSaved(artworkID: artwork.id, isSaved: isSaved(artwork))
        } catch {
            context.rollback()
            notice = "未能保存收藏：\(error.localizedDescription)"
        }
    }

    func openArtwork(id: String) async {
        guard !invalidatedIDs.contains(id) else {
            selectedArtwork = nil; tab = .gallery
            notice = "这件作品的馆藏图片已失效。"; return
        }
        if let artwork = artworks.first(where: { $0.id == id }) { selectedArtwork = artwork; return }
        if let artwork = currentStore.snapshot?.artwork, artwork.id == id {
            merge([artwork]); selectedArtwork = artworks.first { $0.id == id } ?? artwork; return
        }
        do {
            let artwork = try await repository.artwork(id: id)
            merge([artwork]); selectedArtwork = artworks.first { $0.id == id } ?? artwork
        }
        catch {
            selectedArtwork = nil; tab = .gallery
            notice = "这件作品暂时无法打开，已保留当前壁纸。"
        }
    }

    func rotationCandidates(_ settings: RotationSettings) -> [Artwork] {
        RotationCandidateSelector.select(artworks: artworks.filter { !invalidatedIDs.contains($0.id) },
            settings: settings, screens: screens, savedIDs: Set(savedDates.keys), currentDisplayID: currentDisplayID)
    }

    func updateRotation(_ update: (inout RotationSettings) -> Void) {
        let previous = rotation.settings
        var settings = previous
        update(&settings)
        do {
            try rotation.updateSettings(settings)
            if previous != rotation.settings { currentStore.requestWidgetReload() }
            Task { await backgroundService.reconcile(enabled: rotation.settings.enabled) }
        }
        catch { notice = "未能保存自动轮换设置：\(error.localizedDescription)" }
    }

    func captureRotationFilters() {
        updateRotation { settings in
            settings.pool = .currentFilters
            settings.filter = RotationFilter(artist: filter.artist, movement: filter.movement, theme: filter.theme)
        }
    }

    func setWallpaper(_ artwork: Artwork, allScreens: Bool = false, screenID: String? = nil, mode: WallpaperMode = .fill) async {
        let request = WallpaperRequest(artwork: artwork, allScreens: allScreens, screenID: screenID ?? currentDisplayID, mode: mode)
        lastWallpaperRequest = request
        do { try await performWallpaper(request); rotation.recordApplied(artwork) }
        catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch { wallpaperError = error.localizedDescription }
    }

    private func performWallpaper(_ request: WallpaperRequest, allowDownload: Bool = true) async throws {
        guard !isSettingWallpaper else { throw CocoaError(.userCancelled) }
        guard !invalidatedIDs.contains(request.artwork.id) else { throw WallpaperError.rightsNotConfirmed }
        guard let lease = try ProcessFileLock.acquire(at: MuseFrameSharedPaths.url("wallpaper-apply.lock"), blocking: false) else { throw SharedStateError.busy }
        defer { withExtendedLifetime(lease) {} }
        isSettingWallpaper = true
        defer { isSettingWallpaper = false }
        let target: WallpaperTarget = request.allScreens ? .all : request.screenID.map(WallpaperTarget.display) ?? .current
        let profiles = try target.resolve(in: ScreenProfile.current(), currentID: currentDisplayID)
        let ids = Set(profiles.map(\.id))
        let displays = NSScreen.screens.filter { WallpaperEngine.identifier(of: $0).map(ids.contains) == true }
        let receipt = try await WallpaperEngine().set(request.artwork, on: displays, mode: request.mode, allowDownload: allowDownload)
        let thumbnail = await CurrentArtworkStorage.thumbnailData(from: receipt.localImageURL)
        currentStore.update(request.artwork, isSaved: isSaved(request.artwork), thumbnailData: thumbnail,
                            displayIDs: receipt.displayIDs, displayMode: request.mode.rawValue)
        if let error = currentStore.storageError { notice = "壁纸已设置，但作品铭牌未能同步：\(error)" }
    }

    func retryWallpaper() async {
        guard let request = lastWallpaperRequest else { return }
        await setWallpaper(request.artwork, allScreens: request.allScreens, screenID: request.screenID, mode: request.mode)
    }

    func copyInfo(_ artwork: Artwork) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(artwork.displayTitle)\n\(artwork.displayArtist) · \(artwork.dateDisplay)\n\(artwork.museumName)\n\(artwork.sourceURL.absoluteString)", forType: .string)
    }
}
