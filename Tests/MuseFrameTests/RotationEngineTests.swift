import Foundation
import Testing
@testable import MuseFrame

@Suite("Wallpaper rotation")
struct RotationEngineTests {
    private let planner = RotationPlanner()

    @Test func dailyScheduleFollowsLocalTimeAndDST() throws {
        var settings = RotationSettings()
        settings.enabled = true
        settings.dailyMinute = 2 * 60 + 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let midnight = date("2026-03-08T00:00:00-05:00")
        let next = try #require(planner.nextDate(after: midnight, settings: settings, calendar: calendar))
        // 02:30 does not exist on the spring transition: Calendar advances to 03:00.
        #expect(calendar.component(.day, from: next) == 8)
        #expect(calendar.component(.hour, from: next) == 3)
        #expect(calendar.component(.minute, from: next) == 0)
        let following = try #require(planner.nextDate(after: next, settings: settings, calendar: calendar))
        #expect(calendar.component(.day, from: following) == 9)
        #expect(calendar.component(.hour, from: following) == 2)
        #expect(calendar.component(.minute, from: following) == 30)
    }

    @Test func intervalsAreBoundedAndDisabledScheduleHasNoDate() {
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        #expect(planner.nextDate(after: now, settings: settings) == nil)
        settings.enabled = true
        settings.cadence = .hourly
        #expect(planner.nextDate(after: now, settings: settings) == now.addingTimeInterval(3_600))
        settings.cadence = .everyHours
        settings.hours = -100
        #expect(planner.nextDate(after: now, settings: settings) == now.addingTimeInterval(3_600))
        settings.hours = 100
        #expect(planner.nextDate(after: now, settings: settings) == now.addingTimeInterval(24 * 3_600))
        settings.cadence = .onLaunch
        #expect(planner.nextDate(after: now, settings: settings) == nil)
    }

    @Test func historyRetainsThirtyDistinctWorksAndRefreshesRecency() {
        let now = date("2026-10-21T10:00:00Z")
        var history: [RotationHistoryEntry] = []
        for index in 0..<40 {
            history = planner.recording("work-\(index)", at: now.addingTimeInterval(Double(index)), in: history)
        }
        #expect(history.count == 30)
        #expect(history.first?.artworkID == "work-39")
        #expect(history.last?.artworkID == "work-10")
        history = planner.recording("work-20", at: now.addingTimeInterval(100), in: history)
        #expect(history.count == 30)
        #expect(history.first?.artworkID == "work-20")
        #expect(Set(history.map(\.artworkID)).count == 30)
    }

    @Test func candidatesExcludeCurrentRecentDuplicatesAndUnconfirmedRights() {
        let current = artwork("current")
        let recent = artwork("recent")
        let fresh = artwork("fresh")
        let history = [RotationHistoryEntry(artworkID: recent.id, appliedAt: .now)]
        let candidates = planner.preferredCandidates(
            from: [current, recent, fresh, fresh, artwork("private", publicDomain: false)],
            currentArtworkID: current.id, history: history
        )
        #expect(candidates.map(\.id) == [fresh.id])
        #expect(planner.preferredCandidates(from: [current], currentArtworkID: current.id, history: []).isEmpty)
    }

    @Test func smallPoolFallsBackToLeastRecentlyUsedWork() {
        let now = date("2026-10-21T10:00:00Z")
        let works = [artwork("a"), artwork("b"), artwork("c")]
        let history = [
            RotationHistoryEntry(artworkID: "c", appliedAt: now),
            RotationHistoryEntry(artworkID: "b", appliedAt: now.addingTimeInterval(-3_600)),
            RotationHistoryEntry(artworkID: "a", appliedAt: now.addingTimeInterval(-7_200))
        ]
        #expect(planner.preferredCandidates(from: works, currentArtworkID: "c", history: history).map(\.id) == ["a"])
        #expect(planner.orderedCandidates(works, offset: -1).map(\.id) == ["c", "a", "b"])
    }

    @Test func artistMovementAndThemeAreCombined() {
        let matching = artwork("matching", artist: "Monet", movement: "Impressionism", themes: ["Landscape"])
        let filter = RotationFilter(artist: "Monet", movement: "Impressionism", theme: "Landscape")
        let works = [matching, artwork("wrong-artist"), artwork("wrong-theme", artist: "Monet", movement: "Impressionism")]
        #expect(planner.preferredCandidates(from: works, currentArtworkID: nil, history: [], filter: filter).map(\.id) == [matching.id])
    }

    @Test @MainActor func settingsAndRecentHistorySurviveRestart() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotation.json")
        let now = date("2026-10-21T10:00:00Z")
        let engine = RotationEngine(storageURL: url)
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .everyHours
        settings.hours = 12
        settings.pool = .saved
        settings.allDisplays = true
        settings.mode = .fit
        settings.filter = RotationFilter(artist: "Monet", movement: nil, theme: "Landscape")
        try engine.updateSettings(settings, now: now)
        engine.recordApplied(artwork("remembered"), at: now)
        let restored = RotationEngine(storageURL: url)
        #expect(restored.settings == settings)
        #expect(restored.history.map(\.artworkID) == ["remembered"])
        #expect(restored.nextDueDate == now.addingTimeInterval(12 * 3_600))
        #expect(restored.lastError == nil)
    }

    @Test @MainActor func failedPreferenceWriteDoesNotEnableRotation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obstacle = directory.appendingPathComponent("file-not-directory")
        try Data("occupied".utf8).write(to: obstacle)
        let engine = RotationEngine(storageURL: obstacle.appendingPathComponent("rotation.json"))
        var settings = RotationSettings()
        settings.enabled = true
        #expect(throws: (any Error).self) { try engine.updateSettings(settings) }
        #expect(!engine.settings.enabled)
        #expect(engine.nextDueDate == nil)
    }

    @Test @MainActor func damagedStorageDefaultsToDisabledAndKeepsAnError() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rotation.json")
        try Data("invalid archive".utf8).write(to: url)
        let engine = RotationEngine(storageURL: url)
        #expect(!engine.settings.enabled)
        #expect(engine.history.isEmpty)
        #expect(engine.lastError != nil)
    }

    @Test @MainActor func offlineAutomaticRotationUsesOnlyCachedOriginals() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let works = [artwork("cached"), artwork("uncached")]
        var applied: [String] = []
        var downloadPermissions: [Bool] = []
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil },
                     cachedOriginal: { $0.id == "cached" }, apply: { work, _, allowDownload in
            applied.append(work.id)
            downloadPermissions.append(allowDownload)
        }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        engine.isOnline = false
        await engine.checkDue(now: now.addingTimeInterval(3_600), reason: .wake)
        #expect(applied == ["cached"])
        #expect(downloadPermissions == [false])
        #expect(engine.history.first?.artworkID == "cached")
        #expect(engine.nextDueDate == now.addingTimeInterval(7_200))
    }

    @Test @MainActor func offlineWithoutOriginalPreservesDesktopAndSchedule() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let works = [artwork("uncached")]
        var calls = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
                     apply: { _, _, _ in calls += 1 }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        engine.isOnline = false
        await engine.checkDue(now: now.addingTimeInterval(3_600))
        #expect(calls == 0)
        #expect(engine.history.isEmpty)
        #expect(engine.state.lastSuccessAt == nil)
        #expect(engine.nextDueDate == now.addingTimeInterval(3_600))
        #expect(engine.lastError != nil)
    }

    @Test @MainActor func failedApplyDoesNotRecordHistoryAndRetriesAreThrottled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let works = [artwork("failure")]
        var calls = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
                     apply: { _, _, _ in
            calls += 1
            throw URLError(.cannotWriteToFile)
        }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        await engine.checkDue(now: now.addingTimeInterval(3_600))
        await engine.checkDue(now: now.addingTimeInterval(3_601))
        #expect(calls == 1)
        #expect(engine.history.isEmpty)
        #expect(engine.state.lastSuccessAt == nil)
        await engine.checkDue(now: now.addingTimeInterval(3_602), reason: .wake)
        #expect(calls == 2)
        await engine.checkDue(now: now.addingTimeInterval(4_502))
        #expect(calls == 3)
    }

    @Test @MainActor func overdueRestartCatchesUpOnceAndPersistsNextDate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotation.json")
        let initial = date("2026-10-21T10:00:00Z")
        let original = RotationEngine(storageURL: url)
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .everyHours
        settings.hours = 6
        try original.updateSettings(settings, now: initial)
        let engine = RotationEngine(storageURL: url)
        let resumed = initial.addingTimeInterval(20 * 3_600)
        let works = [artwork("next")]
        var calls = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
                     apply: { _, _, _ in calls += 1 }, scheduleAutomatically: false, now: resumed)
        defer { engine.stop() }
        await engine.checkDue(now: resumed, reason: .launch)
        await engine.checkDue(now: resumed.addingTimeInterval(1), reason: .wake)
        #expect(calls == 1)
        #expect(engine.nextDueDate == resumed.addingTimeInterval(6 * 3_600))
        let restored = RotationEngine(storageURL: url)
        #expect(restored.nextDueDate == engine.nextDueDate)
        #expect(restored.history.map(\.artworkID) == ["next"])
    }

    @Test @MainActor func onLaunchRunsOncePerRuntimeAndAgainAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotation.json")
        let now = date("2026-10-21T10:00:00Z")
        let engine = RotationEngine(storageURL: url)
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .onLaunch
        try engine.updateSettings(settings, now: now)
        let works = [artwork("a"), artwork("b")]
        var current: String?
        var calls = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { current }, cachedOriginal: { _ in true },
                     apply: { work, _, _ in current = work.id; calls += 1 }, scheduleAutomatically: false, now: now)
        await engine.checkDue(now: now, reason: .launch)
        await engine.checkDue(now: now.addingTimeInterval(3_600), reason: .wake)
        #expect(calls == 1)
        #expect(engine.nextDueDate == nil)
        settings.pool = .all
        try engine.updateSettings(settings, now: now.addingTimeInterval(3_600))
        await engine.checkDue(now: now.addingTimeInterval(3_601))
        #expect(calls == 1)
        engine.stop()
        let restored = RotationEngine(storageURL: url)
        restored.start(candidateProvider: { _ in works }, currentArtworkID: { current }, cachedOriginal: { _ in true },
                       apply: { work, _, _ in current = work.id; calls += 1 }, scheduleAutomatically: false, now: now)
        defer { restored.stop() }
        await restored.checkDue(now: now.addingTimeInterval(7_200), reason: .launch)
        #expect(calls == 2)
        #expect(restored.history.count == 2)
    }

    @Test @MainActor func manualNextWorksWhileDisabledAndDoesNotMoveSchedule() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let works = [artwork("manual")]
        var downloadAllowed = false
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
                     apply: { _, _, allowed in downloadAllowed = allowed }, scheduleAutomatically: false)
        defer { engine.stop() }
        engine.isOnline = false
        await engine.nextArtwork()
        #expect(downloadAllowed)
        #expect(engine.history.map(\.artworkID) == ["manual"])
        #expect(!engine.settings.enabled)
        #expect(engine.nextDueDate == nil)
    }

    @Test @MainActor func changingCandidatePoolDoesNotPostponeSchedule() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        settings.pool = .saved
        try engine.updateSettings(settings, now: now.addingTimeInterval(1_800))
        #expect(engine.nextDueDate == now.addingTimeInterval(3_600))
        engine.recordApplied(artwork("manual"), at: now.addingTimeInterval(2_000))
        #expect(engine.nextDueDate == now.addingTimeInterval(3_600))
    }

    @Test @MainActor func cachedRecentWorkDoesNotDisplaceUnseenWork() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let recent = artwork("recent")
        let fresh = artwork("fresh")
        engine.recordApplied(recent)
        var applied: String?
        engine.start(candidateProvider: { _ in [recent, fresh] }, currentArtworkID: { nil },
                     cachedOriginal: { $0.id == recent.id }, apply: { work, _, _ in applied = work.id },
                     scheduleAutomatically: false)
        defer { engine.stop() }
        await engine.nextArtwork()
        #expect(applied == fresh.id)
    }

    @Test @MainActor func offlinePoolCanReuseItsOldestCachedWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let cached = artwork("cached-recent")
        let fresh = artwork("uncached-fresh")
        engine.recordApplied(cached, at: now)
        var applied: String?
        engine.start(candidateProvider: { _ in [cached, fresh] }, currentArtworkID: { nil },
                     cachedOriginal: { $0.id == cached.id }, apply: { work, _, allowed in
            #expect(!allowed)
            applied = work.id
        }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        engine.isOnline = false
        await engine.checkDue(now: now.addingTimeInterval(3_600))
        #expect(applied == cached.id)
    }

    @Test @MainActor func pausingDuringCandidateLookupPreventsAutomaticApply() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotation.json")
        let engine = RotationEngine(storageURL: url)
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let gate = RotationTestSuspension()
        let works = [artwork("pending-lookup")]
        var applied = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in
            await gate.suspend()
            return true
        }, apply: { _, _, _ in applied += 1 }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        let pending = Task { await engine.checkDue(now: now.addingTimeInterval(3_600)) }
        await gate.waitUntilSuspended()
        settings.enabled = false
        try engine.updateSettings(settings)
        await gate.release()
        await pending.value
        #expect(applied == 0)
        #expect(engine.history.isEmpty)
        #expect(engine.state.lastSuccessAt == nil)
        #expect(engine.nextDueDate == nil)
        #expect(engine.lastError == nil)
        #expect(!engine.isRotating)
        #expect(!RotationEngine(storageURL: url).settings.enabled)
    }

    @Test @MainActor func pausingCancelsDownloadBeforeAutomaticDesktopWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let gate = RotationTestSuspension()
        let works = [artwork("pending-download")]
        var desktopWrites = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
                     apply: { _, _, _ in
            await gate.suspend()
            // Matches WallpaperEngine's cancellation boundary after obtaining the local file.
            try Task.checkCancellation()
            desktopWrites += 1
        }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        let pending = Task { await engine.checkDue(now: now.addingTimeInterval(3_600)) }
        await gate.waitUntilSuspended()
        settings.enabled = false
        try engine.updateSettings(settings)
        await gate.release()
        await pending.value
        #expect(desktopWrites == 0)
        #expect(engine.history.isEmpty)
        #expect(engine.state.lastSuccessAt == nil)
        #expect(engine.nextDueDate == nil)
        #expect(engine.lastError == nil)
    }

    @Test @MainActor func quickPauseAndResumeCannotReviveTheOldDownloadOrDelayNewSchedule() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        let now = date("2026-10-21T10:00:00Z")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        try engine.updateSettings(settings, now: now)
        let gate = RotationTestSuspension()
        let works = [artwork("pending-resume")]
        var attempts = 0
        var desktopWrites = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
                     apply: { _, _, _ in
            attempts += 1
            if attempts == 1 { await gate.suspend() }
            try Task.checkCancellation()
            desktopWrites += 1
        }, scheduleAutomatically: false, now: now)
        defer { engine.stop() }
        let pending = Task { await engine.checkDue(now: now.addingTimeInterval(3_600)) }
        await gate.waitUntilSuspended()
        settings.enabled = false
        try engine.updateSettings(settings, now: now.addingTimeInterval(3_630))
        settings.enabled = true
        let resumed = now.addingTimeInterval(3_660)
        try engine.updateSettings(settings, now: resumed)
        await gate.release()
        await pending.value
        #expect(desktopWrites == 0)
        #expect(engine.nextDueDate == resumed.addingTimeInterval(3_600))
        await engine.checkDue(now: resumed.addingTimeInterval(3_601))
        #expect(desktopWrites == 1)
        #expect(attempts == 2)
        #expect(engine.history.count == 1)
    }

    @Test @MainActor func pausingDoesNotCancelUserRequestedNextArtwork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RotationEngine(storageURL: directory.appendingPathComponent("rotation.json"))
        var settings = RotationSettings()
        settings.enabled = true
        try engine.updateSettings(settings)
        let gate = RotationTestSuspension()
        let works = [artwork("manual-during-pause")]
        var desktopWrites = 0
        engine.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
                     apply: { _, _, _ in
            await gate.suspend()
            try Task.checkCancellation()
            desktopWrites += 1
        }, scheduleAutomatically: false)
        defer { engine.stop() }
        let pending = Task { await engine.nextArtwork() }
        await gate.waitUntilSuspended()
        settings.enabled = false
        try engine.updateSettings(settings)
        await gate.release()
        await pending.value
        #expect(desktopWrites == 1)
        #expect(engine.history.map(\.artworkID) == ["manual-during-pause"])
        #expect(!engine.settings.enabled)
        #expect(engine.nextDueDate == nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MuseFrame-Rotation-\(UUID().uuidString)", isDirectory: true)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func artwork(_ id: String, artist: String = "Test Artist", movement: String = "Other",
                         themes: [String] = [], publicDomain: Bool = true) -> Artwork {
        let url = URL(string: "https://example.org/\(id).jpg")!
        return Artwork(id: id, source: .met, sourceID: id, titleOriginal: id,
                       artistOriginal: artist, dateDisplay: "1900", movement: movement, themes: themes,
                       museumName: "Test Museum", sourceURL: url,
                       image: ArtworkImage(originalURL: url, thumbnailURL: url, width: 6_000, height: 4_000, license: "CC0 1.0"),
                       isPublicDomain: publicDomain)
    }
}

/// A controllable download boundary; tests never use timing sleeps or native desktop APIs.
private actor RotationTestSuspension {
    private var pending: CheckedContinuation<Void, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            for waiter in entered { waiter.resume() }
            entered.removeAll()
        }
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func release() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}
