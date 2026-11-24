import Foundation

struct RotationDueToken: Equatable, Sendable {
    let settingsRevision: UInt64
    let dueDate: Date?
    let launchEventID: UUID?
}

struct RotationArchive: Codable, Sendable {
    var version = 2
    var settings = RotationSettings()
    var state = RotationState()
    var settingsRevision: UInt64 = 0
    var launchEventID: UUID?
    var launchEventAt: Date?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, settings, state, settingsRevision, launchEventID, launchEventAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw SharedStateError.invalidArchive }
        settings = try values.decode(RotationSettings.self, forKey: .settings).normalized
        state = try values.decode(RotationState.self, forKey: .state)
        settingsRevision = try values.decodeIfPresent(UInt64.self, forKey: .settingsRevision) ?? 0
        launchEventID = try values.decodeIfPresent(UUID.self, forKey: .launchEventID)
        launchEventAt = try values.decodeIfPresent(Date.self, forKey: .launchEventAt)
        var seen: Set<String> = []
        state.history = Array(state.history.filter {
            !$0.artworkID.isEmpty && seen.insert($0.artworkID).inserted
        }.prefix(RotationPlanner.historyLimit))
    }

    func dueToken(at now: Date, ignoringRetry: Bool = false) -> RotationDueToken? {
        guard settings.enabled else { return nil }
        if !ignoringRetry, let retry = state.retryNotBefore, retry > now { return nil }
        if settings.cadence == .onLaunch {
            guard let launchEventID, launchEventID != state.consumedLaunchEventID else { return nil }
            return RotationDueToken(settingsRevision: settingsRevision, dueDate: nil, launchEventID: launchEventID)
        }
        guard let due = state.nextDueDate, due <= now else { return nil }
        return RotationDueToken(settingsRevision: settingsRevision, dueDate: due, launchEventID: nil)
    }

    func stillAuthorizes(_ token: RotationDueToken) -> Bool {
        guard settings.enabled, settingsRevision == token.settingsRevision else { return false }
        if settings.cadence == .onLaunch {
            return token.launchEventID != nil && token.launchEventID == launchEventID
                && token.launchEventID != state.consumedLaunchEventID
        }
        return token.launchEventID == nil && token.dueDate == state.nextDueDate
    }
}

/// A read-only projection of the GUI's catalog and SwiftData collection, not a second favorites database.
struct SharedRotationLibrary: Codable, Equatable, Sendable {
    var version = 1
    let artworks: [Artwork]
    let savedIDs: Set<String>
    let updatedAt: Date

    func authorizes(_ artwork: Artwork, settings: RotationSettings) -> Bool {
        guard let latest = artworks.first(where: { $0.id == artwork.id }), latest.isPublicDomain,
              !latest.image.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latest.image.originalURL == artwork.image.originalURL,
              settings.filter.matches(latest) else { return false }
        return settings.pool != .saved || savedIDs.contains(artwork.id)
    }
}

enum RotationCandidateSelector {
    static func select(artworks: [Artwork], settings: RotationSettings, screens: [ScreenProfile],
                       savedIDs: Set<String>, currentDisplayID: String? = nil) -> [Artwork] {
        var seen: Set<String> = []
        var candidates = artworks.filter {
            $0.isPublicDomain && !$0.image.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && settings.filter.matches($0) && seen.insert($0.id).inserted
        }
        switch settings.pool {
        case .saved:
            candidates.removeAll { !savedIDs.contains($0.id) }
        case .fitsScreen:
            let target: WallpaperTarget = settings.allDisplays ? .all : settings.screenID.map(WallpaperTarget.display) ?? .main
            let targets = (try? target.resolve(in: screens, currentID: currentDisplayID)) ?? []
            candidates.removeAll { artwork in
                targets.isEmpty || !targets.allSatisfy { ScreenFitEngine().evaluate(artwork, screen: $0).qualifies }
            }
        case .all, .currentFilters:
            break
        }
        return candidates
    }

    static func select(library: SharedRotationLibrary, settings: RotationSettings, screens: [ScreenProfile],
                       currentDisplayID: String? = nil) -> [Artwork] {
        select(artworks: library.artworks, settings: settings, screens: screens,
               savedIDs: library.savedIDs, currentDisplayID: currentDisplayID)
    }
}

/// Every mutation rereads the latest archive while holding the same permanent lock file.
/// Atomic replacement alone prevents torn JSON, but cannot prevent lost updates between processes.
struct RotationSharedStore: Sendable {
    let storageURL: URL
    let legacyURL: URL?
    var lockURL: URL { storageURL.appendingPathExtension("lock") }
    var libraryURL: URL { storageURL.deletingLastPathComponent().appendingPathComponent("rotation-library.json") }

    init(storageURL: URL, legacyURL: URL? = nil) {
        self.storageURL = storageURL
        self.legacyURL = legacyURL
    }

    func load() throws -> RotationArchive {
        try ProcessFileLock.withLock(at: lockURL) { try readLocked() }
    }

    @discardableResult
    func updateSettings(_ proposed: RotationSettings, base: RotationSettings? = nil,
                        now: Date = .now) throws -> RotationArchive {
        try transaction { archive in
            let old = archive.settings
            let next = base.map { old.applyingChanges(from: $0, to: proposed) } ?? proposed.normalized
            guard old != next else { return }
            let cadenceChanged = old.cadence != next.cadence
                || (next.cadence == .everyHours && old.hours != next.hours)
                || (next.cadence == .daily && old.dailyMinute != next.dailyMinute)
            if !next.enabled {
                archive.state.nextDueDate = nil
            } else if !old.enabled || cadenceChanged {
                archive.state.nextDueDate = RotationPlanner().nextDate(after: now, settings: next)
            }
            if next.enabled && next.cadence == .onLaunch && (!old.enabled || cadenceChanged) {
                archive.launchEventID = UUID()
                archive.launchEventAt = now
            }
            archive.settings = next
            guard archive.settingsRevision < .max else { throw SharedStateError.invalidArchive }
            archive.settingsRevision += 1
            archive.state.retryNotBefore = nil
        }
    }

    @discardableResult
    func publishLaunchEvent(id: UUID = UUID(), at date: Date = .now) throws -> RotationArchive {
        try transaction { archive in
            guard archive.launchEventID != id else { return }
            archive.launchEventID = id
            archive.launchEventAt = date
            archive.state.retryNotBefore = nil
        }
    }

    @discardableResult
    func initializeSchedule(now: Date) throws -> RotationArchive {
        try transaction { archive in
            if archive.settings.enabled && archive.settings.cadence != .onLaunch && archive.state.nextDueDate == nil {
                archive.state.nextDueDate = RotationPlanner().nextDate(
                    after: archive.state.lastSuccessAt ?? now, settings: archive.settings
                )
            }
        }
    }

    @discardableResult
    func recordApplied(_ artworkID: String, at date: Date) throws -> RotationArchive {
        try transaction { archive in
            archive.state.history = RotationPlanner().recording(artworkID, at: date, in: archive.state.history)
        }
    }

    @discardableResult
    func finishAutomatic(_ artworkID: String, token: RotationDueToken, at date: Date) throws -> RotationArchive {
        try transaction { archive in
            archive.state.history = RotationPlanner().recording(artworkID, at: date, in: archive.state.history)
            archive.state.lastSuccessAt = date
            // A settings change after the native write owns its new schedule; never overwrite it.
            if archive.stillAuthorizes(token) {
                archive.state.nextDueDate = RotationPlanner().nextDate(after: date, settings: archive.settings)
                archive.state.consumedLaunchEventID = token.launchEventID ?? archive.state.consumedLaunchEventID
                archive.state.retryNotBefore = nil
            }
        }
    }

    @discardableResult
    func recordFailure(token: RotationDueToken, retryAt: Date) throws -> RotationArchive {
        try transaction { archive in
            if archive.stillAuthorizes(token) { archive.state.retryNotBefore = retryAt }
        }
    }

    /// Only perform a synchronous native desktop write here. Reentering this store would deadlock.
    /// The separate wallpaper execution lease must be acquired before entering this short transaction.
    func withAutomaticAuthorization<T>(token: RotationDueToken, settings: RotationSettings, artwork: Artwork? = nil,
                                       _ operation: () throws -> T) throws -> T {
        try ProcessFileLock.withLock(at: lockURL) {
            let archive = try readLocked()
            guard archive.stillAuthorizes(token), archive.settings == settings else { throw CancellationError() }
            if let artwork {
                guard let library = try readLibraryLocked(), library.authorizes(artwork, settings: settings) else {
                    throw CancellationError()
                }
            }
            try Task.checkCancellation()
            return try operation()
        }
    }

    func loadLibrary() throws -> SharedRotationLibrary? {
        try ProcessFileLock.withLock(at: lockURL) { try readLibraryLocked() }
    }

    func withLatestLibrary<T>(_ operation: (SharedRotationLibrary?) throws -> T) throws -> T {
        try ProcessFileLock.withLock(at: lockURL) { try operation(readLibraryLocked()) }
    }

    @discardableResult
    func publishLibrary(artworks: [Artwork], savedIDs: Set<String>, at date: Date = .now) throws -> SharedRotationLibrary {
        let result = try ProcessFileLock.withLock(at: lockURL) {
            var seen: Set<String> = []
            let works = artworks.filter { seen.insert($0.id).inserted }
            let library = SharedRotationLibrary(artworks: works, savedIDs: savedIDs, updatedAt: date)
            try JSONEncoder().encode(library).write(to: libraryURL, options: .atomic)
            var archive = try readLocked()
            if archive.state.retryNotBefore != nil {
                archive.state.retryNotBefore = nil
                try writeLocked(archive)
            }
            return library
        }
        MuseFrameSharedPaths.notifyChange()
        return result
    }

    private func transaction(_ body: (inout RotationArchive) throws -> Void) throws -> RotationArchive {
        let archive = try ProcessFileLock.withLock(at: lockURL) {
            var latest = try readLocked()
            try body(&latest)
            try writeLocked(latest)
            return latest
        }
        MuseFrameSharedPaths.notifyChange()
        return archive
    }

    private func readLocked() throws -> RotationArchive {
        let manager = FileManager.default
        let source: URL
        if manager.fileExists(atPath: storageURL.path) {
            source = storageURL
        } else if let legacyURL, legacyURL.standardizedFileURL != storageURL.standardizedFileURL,
                  manager.fileExists(atPath: legacyURL.path) {
            source = legacyURL
        } else { return RotationArchive() }
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? .max) <= 1_048_576 else { throw SharedStateError.invalidArchive }
        var archive = try JSONDecoder().decode(RotationArchive.self, from: Data(contentsOf: source))
        if archive.version == 1 || source != storageURL {
            archive.version = 2
            try writeLocked(archive)
        }
        return archive
    }

    private func writeLocked(_ archive: RotationArchive) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: storageURL, options: .atomic)
    }

    private func readLibraryLocked() throws -> SharedRotationLibrary? {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return nil }
        let values = try FileManager.default.attributesOfItem(atPath: libraryURL.path)
        guard ((values[.size] as? NSNumber)?.int64Value ?? .max) <= 20_971_520 else { throw SharedStateError.invalidArchive }
        let library = try JSONDecoder().decode(SharedRotationLibrary.self, from: Data(contentsOf: libraryURL))
        guard library.version == 1 else { throw SharedStateError.invalidArchive }
        return library
    }
}

private extension RotationSettings {
    func applyingChanges(from base: Self, to proposed: Self) -> Self {
        var result = self
        if proposed.enabled != base.enabled { result.enabled = proposed.enabled }
        if proposed.cadence != base.cadence { result.cadence = proposed.cadence }
        if proposed.hours != base.hours { result.hours = proposed.hours }
        if proposed.dailyMinute != base.dailyMinute { result.dailyMinute = proposed.dailyMinute }
        if proposed.pool != base.pool { result.pool = proposed.pool }
        if proposed.filter != base.filter { result.filter = proposed.filter }
        if proposed.allDisplays != base.allDisplays { result.allDisplays = proposed.allDisplays }
        if proposed.screenID != base.screenID { result.screenID = proposed.screenID }
        if proposed.mode != base.mode { result.mode = proposed.mode }
        return result.normalized
    }
}
