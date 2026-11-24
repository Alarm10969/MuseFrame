import AppKit
import Foundation

/// No UI, catalog synchronization or SwiftData access: the GUI publishes a read-only library.
@MainActor final class BackgroundRotationRuntime {
    let rotation: RotationEngine
    let currentStore: CurrentArtworkStore
    private let root: URL
    private let sessionID = UUID()
    private var lifetimeLease: ProcessFileLock?
    private var heartbeat: Task<Void, Never>?
    private var check: Task<Void, Never>?
    private var applicationError: String?

    init() throws {
        root = try MuseFrameSharedPaths.requireRoot()
        rotation = RotationEngine()
        currentStore = CurrentArtworkStore()
    }

    deinit { heartbeat?.cancel(); check?.cancel() }

    func start(scheduleAutomatically: Bool = true) throws {
        guard lifetimeLease == nil else { return }
        guard let lease = try ProcessFileLock.acquire(at: root.appendingPathComponent("helper-runtime.lock"), blocking: false) else {
            throw SharedStateError.busy
        }
        lifetimeLease = lease
        rotation.start(candidateProvider: { [weak self] settings in
            guard let library = self?.rotation.library else { return [] }
            return RotationCandidateSelector.select(library: library, settings: settings, screens: ScreenProfile.current())
        }, currentArtworkID: { [weak self] in
            self?.currentStore.reloadFromDisk()
            return self?.currentStore.snapshot?.artworkID
        }, cachedOriginal: { artwork in
            if await ImageCache.shared.cachedFileURL(for: artwork, purpose: .wallpaper) != nil { return true }
            return await MainActor.run { WallpaperEngine().existingDesktopImage(for: artwork) != nil }
        }, apply: { [weak self] artwork, settings, allowDownload in
            guard let self else { throw CancellationError() }
            try await self.apply(artwork, settings: settings, allowDownload: allowDownload)
        }, didCommitAutomatic: { [weak self] in
            self?.currentStore.requestDeferredWidgetReload()
        }, scheduleAutomatically: scheduleAutomatically, publishLaunchEvent: false)
        writeHeartbeat()
        guard scheduleAutomatically else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                self.currentStore.reloadFromDisk()
                do { try self.rotation.refreshFromDisk() }
                catch { self.applicationError = error.localizedDescription }
                self.writeHeartbeat()
                // A separate task keeps liveness and disable checks responsive during image I/O.
                if self.check == nil {
                    self.check = Task { [weak self] in
                        await self?.rotation.checkDue()
                        self?.check = nil
                    }
                }
            }
        }
    }

    func checkOnce() async { await rotation.checkDue(); writeHeartbeat(); currentStore.flushWidgetReload() }

    func stop() {
        heartbeat?.cancel(); heartbeat = nil
        check?.cancel(); check = nil
        rotation.stop()
        currentStore.flushWidgetReload()
        lifetimeLease = nil
    }

    private func apply(_ artwork: Artwork, settings: RotationSettings, allowDownload: Bool) async throws {
        guard let lease = try ProcessFileLock.acquire(at: root.appendingPathComponent("wallpaper-apply.lock"), blocking: false) else {
            throw SharedStateError.busy
        }
        defer { withExtendedLifetime(lease) {} }
        do {
            let target: WallpaperTarget = settings.allDisplays ? .all : settings.screenID.map(WallpaperTarget.display) ?? .main
            let profiles = try target.resolve(in: ScreenProfile.current(), currentID: nil)
            let ids = Set(profiles.map(\.id))
            let screens = NSScreen.screens.filter { WallpaperEngine.identifier(of: $0).map(ids.contains) == true }
            let receipt = try await WallpaperEngine().set(artwork, on: screens, mode: settings.mode,
                allowDownload: allowDownload, authorizeApply: { [rotation] operation in
                    if settings.pool == .fitsScreen {
                        guard RotationCandidateSelector.select(artworks: [artwork], settings: settings,
                            screens: ScreenProfile.current(), savedIDs: []).contains(where: { $0.id == artwork.id }) else {
                            throw CancellationError()
                        }
                    }
                    try rotation.withAutomaticApplyAuthorization(settings: settings, operation)
                })
            let thumbnail = await CurrentArtworkStorage.thumbnailData(from: receipt.localImageURL)
            // Saved may have changed while downloading. Read the GUI's latest projection.
            do {
                try rotation.withLatestLibrary { library in
                    currentStore.update(artwork, isSaved: library?.savedIDs.contains(artwork.id) == true,
                        thumbnailData: thumbnail, displayIDs: receipt.displayIDs, displayMode: settings.mode.rawValue,
                        deferWidgetReload: true)
                }
                applicationError = currentStore.storageError.map { "壁纸已设置，但作品状态未能同步：\($0)" }
            } catch { applicationError = "壁纸已设置，但作品状态未能同步：\(error.localizedDescription)" }
            // Native application succeeded: a DTO failure must not cause a second desktop change.
            writeHeartbeat()
        } catch {
            applicationError = error is CancellationError ? nil : error.localizedDescription
            writeHeartbeat()
            throw error
        }
    }

    private func writeHeartbeat() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.5"
        let receipt = BackgroundHelperStatus(processID: ProcessInfo.processInfo.processIdentifier,
            sessionID: sessionID, checkedAt: .now, version: version, lastError: applicationError ?? rotation.lastError)
        do { try receipt.save(directory: root) }
        catch { applicationError = "后台状态无法写入：\(error.localizedDescription)" }
    }
}
