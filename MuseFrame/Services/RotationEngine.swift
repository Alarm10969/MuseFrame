import AppKit
import Foundation
import Network
import Observation

enum RotationPool: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, saved, fitsScreen, currentFilters

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "所有作品"
        case .saved: "Saved"
        case .fitsScreen: "Fits your screen"
        case .currentFilters: "当前筛选"
        }
    }
}

/// A saved selection is independent of subsequent browsing in the gallery.
struct RotationFilter: Codable, Equatable, Sendable {
    var artist: String?
    var movement: String?
    var theme: String?

    func matches(_ artwork: Artwork) -> Bool {
        if let artist, artwork.artistOriginal != artist { return false }
        if let movement, artwork.movement != movement { return false }
        if let theme, !artwork.themes.contains(theme) { return false }
        return true
    }

    var normalized: Self {
        func value(_ text: String?) -> String? {
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        return Self(artist: value(artist), movement: value(movement), theme: value(theme))
    }
}

struct RotationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var cadence = RotationCadence.daily
    var hours = 6
    /// Minutes since local midnight; the daily schedule follows the user's calendar.
    var dailyMinute = 8 * 60
    var pool = RotationPool.fitsScreen
    var filter = RotationFilter()
    var allDisplays = false
    var screenID: String?
    var mode = WallpaperMode.fill

    var normalized: Self {
        var copy = self
        copy.hours = min(24, max(1, hours))
        copy.dailyMinute = min(1_439, max(0, dailyMinute))
        copy.filter = filter.normalized
        return copy
    }
}

struct RotationHistoryEntry: Codable, Equatable, Sendable {
    let artworkID: String
    let appliedAt: Date
}

struct RotationState: Codable, Equatable, Sendable {
    var lastSuccessAt: Date?
    var nextDueDate: Date?
    /// Newest first, with one entry per artwork, retaining at most thirty entries.
    var history: [RotationHistoryEntry] = []
    var retryNotBefore: Date?
    var consumedLaunchEventID: UUID?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lastSuccessAt, nextDueDate, history, retryNotBefore, consumedLaunchEventID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastSuccessAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        nextDueDate = try values.decodeIfPresent(Date.self, forKey: .nextDueDate)
        history = try values.decodeIfPresent([RotationHistoryEntry].self, forKey: .history) ?? []
        retryNotBefore = try values.decodeIfPresent(Date.self, forKey: .retryNotBefore)
        consumedLaunchEventID = try values.decodeIfPresent(UUID.self, forKey: .consumedLaunchEventID)
    }
}

enum RotationCheckReason: Equatable, Sendable {
    case timer, launch, wake
}

/// Calendar and candidate selection have no application or desktop side effects.
struct RotationPlanner: Sendable {
    static let historyLimit = 30

    func nextDate(after date: Date, settings: RotationSettings,
                  calendar: Calendar = .autoupdatingCurrent) -> Date? {
        RotationSchedule(enabled: settings.enabled, cadence: settings.cadence,
            hours: settings.hours, dailyMinute: settings.dailyMinute).nextDate(after: date, calendar: calendar)
    }

    func recording(_ artworkID: String, at date: Date,
                   in history: [RotationHistoryEntry]) -> [RotationHistoryEntry] {
        guard !artworkID.isEmpty else { return Array(history.prefix(Self.historyLimit)) }
        var seen: Set<String> = [artworkID]
        let previous = history.filter { !$0.artworkID.isEmpty && seen.insert($0.artworkID).inserted }
        return [RotationHistoryEntry(artworkID: artworkID, appliedAt: date)]
            + previous.prefix(Self.historyLimit - 1)
    }

    /// Prefer unseen work. If the pool is smaller than the history, reuse its oldest work.
    /// Current artwork is excluded even for a one-work pool, avoiding a pointless desktop write.
    func preferredCandidates(from artworks: [Artwork], currentArtworkID: String?,
                             history: [RotationHistoryEntry], filter: RotationFilter = .init()) -> [Artwork] {
        var seen: Set<String> = []
        let candidates = artworks.filter {
            $0.id != currentArtworkID && $0.isPublicDomain
                && !$0.image.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && filter.matches($0) && seen.insert($0.id).inserted
        }.sorted { $0.id < $1.id }
        let dates = Dictionary(history.map { ($0.artworkID, $0.appliedAt) }, uniquingKeysWith: max)
        let unseen = candidates.filter { dates[$0.id] == nil }
        if !unseen.isEmpty { return unseen }
        guard let oldest = candidates.min(by: {
            let left = dates[$0.id] ?? .distantPast
            let right = dates[$1.id] ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }) else { return [] }
        return [oldest]
    }

    /// The caller supplies an offset, making selection reproducible in tests.
    func orderedCandidates(_ candidates: [Artwork], offset: Int) -> [Artwork] {
        guard !candidates.isEmpty else { return [] }
        let index = (offset % candidates.count + candidates.count) % candidates.count
        return Array(candidates[index...]) + candidates[..<index]
    }
}

/// NotificationCenter owns its observer; this token removes it when the runtime is released.
private final class RotationWakeObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}

/// The GUI observes shared state; the helper alone enables automatic scheduling.
/// Applying the desktop remains injected, so unit tests never change the user's wallpaper.
@MainActor @Observable
final class RotationEngine {
    typealias CandidateProvider = @MainActor (RotationSettings) -> [Artwork]
    typealias CurrentArtworkProvider = @MainActor () -> String?
    typealias CachedOriginal = @Sendable (Artwork) async -> Bool
    typealias Apply = @MainActor (Artwork, RotationSettings, Bool) async throws -> Void
    typealias DidCommitAutomatic = @MainActor () -> Void

    private struct PendingAutomaticCommit {
        let artworkID: String
        let token: RotationDueToken
        let appliedAt: Date
    }

    private(set) var settings = RotationSettings()
    private(set) var state = RotationState()
    private(set) var settingsRevision: UInt64 = 0
    private(set) var library: SharedRotationLibrary?
    private(set) var isRunning = false
    private(set) var isRotating = false
    private(set) var lastError: String?
    var isOnline = true

    var nextDueDate: Date? { state.nextDueDate }
    var history: [RotationHistoryEntry] { state.history }
    var isPerformingAutomaticRotation: Bool { activeAutomaticToken != nil }

    @ObservationIgnored private let store: RotationSharedStore?
    @ObservationIgnored private let planner = RotationPlanner()
    @ObservationIgnored private var archive = RotationArchive()
    @ObservationIgnored private var candidates: CandidateProvider?
    @ObservationIgnored private var currentArtwork: CurrentArtworkProvider?
    @ObservationIgnored private var cachedOriginal: CachedOriginal?
    @ObservationIgnored private var apply: Apply?
    @ObservationIgnored private var didCommitAutomatic: DidCommitAutomatic?
    @ObservationIgnored private var pendingAutomaticCommit: PendingAutomaticCommit?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var automaticTask: Task<Artwork?, Never>?
    @ObservationIgnored private var activeAutomaticToken: RotationDueToken?
    @ObservationIgnored private var activeAutomaticArtwork: Artwork?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var wakeObservation: RotationWakeObservation?
    @ObservationIgnored private var sharedObservation: RotationWakeObservation?

    init(storageURL: URL? = nil) {
        if let storageURL {
            store = RotationSharedStore(storageURL: storageURL)
        } else if let root = MuseFrameSharedPaths.root {
            let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MuseFrame/rotation-state.json")
            store = RotationSharedStore(storageURL: root.appendingPathComponent("rotation-state.json"), legacyURL: legacy)
        } else {
            store = nil
        }
        do { try refreshFromDisk() }
        catch { lastError = "未能读取自动轮换设置：\(error.localizedDescription)" }
    }

    deinit {
        ticker?.cancel()
        automaticTask?.cancel()
        monitor?.cancel()
    }

    func updateSettings(_ proposed: RotationSettings, now: Date = .now) throws {
        let latest = try sharedStore().updateSettings(proposed, base: settings, now: now)
        adopt(latest)
        lastError = nil
    }

    /// Notifications are hints. Every worker check and final authorization rereads the file too.
    func refreshFromDisk() throws {
        let shared = try sharedStore()
        adopt(try shared.load())
        do {
            library = try shared.loadLibrary()
            if let activeAutomaticArtwork, let library,
               !library.authorizes(activeAutomaticArtwork, settings: settings) { automaticTask?.cancel() }
        }
        catch {
            library = nil
            automaticTask?.cancel()
            throw error
        }
    }

    @discardableResult
    func publishLaunchEvent(id: UUID = UUID(), at date: Date = .now) throws -> UUID {
        adopt(try sharedStore().publishLaunchEvent(id: id, at: date))
        return id
    }

    /// The GUI is the sole publisher; the helper treats this as a read-only projection.
    func publishLibrary(artworks: [Artwork], savedIDs: Set<String>) throws {
        library = try sharedStore().publishLibrary(artworks: artworks, savedIDs: savedIDs)
    }

    /// Keeps collection projection and the current-artwork commit in one ordering window.
    func withLatestLibrary<T>(_ operation: (SharedRotationLibrary?) throws -> T) throws -> T {
        try sharedStore().withLatestLibrary(operation)
    }

    /// Call around a synchronous native desktop write, after the execution lease is held.
    /// This is for automatic requests only. Manual Set/Next intentionally bypass enabled checks.
    func withAutomaticApplyAuthorization<T>(settings: RotationSettings, _ operation: () throws -> T) throws -> T {
        guard let token = activeAutomaticToken else { throw CancellationError() }
        do {
            return try sharedStore().withAutomaticAuthorization(token: token, settings: settings,
                artwork: activeAutomaticArtwork, operation)
        } catch is CancellationError {
            automaticTask?.cancel()
            throw CancellationError()
        }
    }

    func start(candidateProvider: @escaping CandidateProvider,
               currentArtworkID: @escaping CurrentArtworkProvider,
               cachedOriginal: @escaping CachedOriginal,
               apply: @escaping Apply,
               didCommitAutomatic: @escaping DidCommitAutomatic = {},
               scheduleAutomatically: Bool = true,
               publishLaunchEvent: Bool = true,
               observeSharedChanges: Bool = true,
               now: Date = .now) {
        guard !isRunning else { return }
        candidates = candidateProvider
        currentArtwork = currentArtworkID
        self.cachedOriginal = cachedOriginal
        self.apply = apply
        self.didCommitAutomatic = didCommitAutomatic
        isRunning = true
        do {
            if publishLaunchEvent { try self.publishLaunchEvent(at: now) }
            adopt(try sharedStore().initializeSchedule(now: now))
            try refreshFromDisk()
        } catch { lastError = "未能读取自动轮换设置：\(error.localizedDescription)" }

        if observeSharedChanges {
            let sharedCenter = DistributedNotificationCenter.default()
            let sharedToken = sharedCenter.addObserver(forName: MuseFrameSharedPaths.changeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        do { try self?.refreshFromDisk() }
                        catch { self?.lastError = "未能读取共享轮换记录：\(error.localizedDescription)" }
                    }
                }
            sharedObservation = RotationWakeObservation(center: sharedCenter, token: sharedToken)
        }
        guard scheduleAutomatically else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "io.museframe.rotation-network", qos: .utility))
        self.monitor = monitor
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkDue(reason: .wake) }
        }
        wakeObservation = RotationWakeObservation(center: center, token: token)
        ticker = Task { [weak self] in
            await self?.checkDue(now: now, reason: .launch)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.checkDue(reason: .timer)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        automaticTask?.cancel()
        ticker = nil
        monitor?.cancel()
        monitor = nil
        wakeObservation = nil
        sharedObservation = nil
        isRunning = false
        candidates = nil
        currentArtwork = nil
        cachedOriginal = nil
        apply = nil
        didCommitAutomatic = nil
    }

    /// A late timer or wake changes once; a helper restart never manufactures a launch event.
    func checkDue(now: Date = .now, reason: RotationCheckReason = .timer) async {
        guard isRunning, !isRotating, automaticTask == nil else { return }
        if pendingAutomaticCommit != nil {
            finishPendingAutomaticCommit()
            return
        }
        do { try refreshFromDisk() }
        catch { lastError = "未能读取自动轮换设置：\(error.localizedDescription)"; return }
        guard let token = archive.dueToken(at: now, ignoringRetry: reason == .wake) else { return }
        activeAutomaticToken = token
        let task = Task { [weak self] in
            guard let self else { return nil as Artwork? }
            return await self.rotate(now: now, manual: false)
        }
        automaticTask = task
        defer { automaticTask = nil; activeAutomaticToken = nil }
        let artwork = await task.value
        if let artwork {
            // Native application already succeeded. A state-file error may retry this
            // commit, but must never select/apply another wallpaper for the same due event.
            pendingAutomaticCommit = PendingAutomaticCommit(artworkID: artwork.id, token: token, appliedAt: now)
            finishPendingAutomaticCommit()
            return
        }
        do {
            adopt(try sharedStore().load())
            if !task.isCancelled && isRunning {
                adopt(try sharedStore().recordFailure(token: token, retryAt: now.addingTimeInterval(15 * 60)))
            }
        } catch { lastError = "未能保存自动轮换设置：\(error.localizedDescription)" }
    }

    private func finishPendingAutomaticCommit() {
        guard let pending = pendingAutomaticCommit else { return }
        do {
            adopt(try sharedStore().finishAutomatic(pending.artworkID, token: pending.token, at: pending.appliedAt))
            pendingAutomaticCommit = nil
            lastError = nil
            // Widget readers must see the advanced schedule as well as the new DTO.
            // Clear the pending success before calling out, so reentrancy cannot hint twice.
            didCommitAutomatic?()
        } catch { lastError = "未能保存自动轮换设置：\(error.localizedDescription)" }
    }

    func nextArtwork() async {
        do { try refreshFromDisk() }
        catch { lastError = "未能读取自动轮换设置：\(error.localizedDescription)"; return }
        _ = await rotate(now: .now, manual: true)
    }

    /// Manual history patches the latest archive without moving its schedule or replacing settings.
    func recordApplied(_ artwork: Artwork, at date: Date = .now) {
        do { adopt(try sharedStore().recordApplied(artwork.id, at: date)) }
        catch { lastError = "未能保存自动轮换设置：\(error.localizedDescription)" }
    }

    private func rotate(now: Date, manual: Bool) async -> Artwork? {
        guard !Task.isCancelled, !isRotating, let candidates, let currentArtwork, let cachedOriginal, let apply else { return nil }
        isRotating = true
        defer { isRotating = false; if !manual { activeAutomaticArtwork = nil } }
        let requestSettings = settings
        let available = candidates(requestSettings)
        let preferred = planner.preferredCandidates(from: available, currentArtworkID: currentArtwork(),
            history: state.history, filter: requestSettings.filter)
        guard !preferred.isEmpty else { lastError = "当前来源没有其他可轮换的作品。"; return nil }
        let ordered = planner.orderedCandidates(preferred, offset: Int.random(in: 0..<preferred.count))
        var selected: Artwork?
        for candidate in ordered {
            let cached = await cachedOriginal(candidate)
            guard !Task.isCancelled else { return nil }
            if cached { selected = candidate; break }
        }
        if selected == nil && !manual && !isOnline {
            let eligible = planner.preferredCandidates(from: available, currentArtworkID: currentArtwork(),
                history: [], filter: requestSettings.filter)
            var cached: [Artwork] = []
            for candidate in eligible {
                let available = await cachedOriginal(candidate)
                guard !Task.isCancelled else { return nil }
                if available { cached.append(candidate) }
            }
            selected = planner.preferredCandidates(from: cached, currentArtworkID: currentArtwork(),
                history: state.history, filter: requestSettings.filter).randomElement()
        }
        if selected == nil && (manual || isOnline) { selected = ordered.first }
        guard let selected else { lastError = "离线时没有可用的高清缓存，已保留当前壁纸。"; return nil }
        do {
            try Task.checkCancellation()
            if !manual {
                guard let token = activeAutomaticToken,
                      try sharedStore().load().stillAuthorizes(token) else { throw CancellationError() }
                activeAutomaticArtwork = selected
            }
            try await apply(selected, requestSettings, manual || isOnline)
            if manual { recordApplied(selected, at: now) }
            if lastError?.hasPrefix("未能保存自动轮换设置") != true { lastError = nil }
            return selected
        } catch is CancellationError {
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func adopt(_ latest: RotationArchive) {
        if let activeAutomaticToken, !latest.stillAuthorizes(activeAutomaticToken) { automaticTask?.cancel() }
        archive = latest
        settings = latest.settings
        settingsRevision = latest.settingsRevision
        state = latest.state
    }

    private func sharedStore() throws -> RotationSharedStore {
        guard let store else { throw SharedStateError.unavailableContainer }
        return store
    }
}
