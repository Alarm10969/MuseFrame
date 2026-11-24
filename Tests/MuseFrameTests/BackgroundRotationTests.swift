import Darwin
import Foundation
import Testing
@testable import MuseFrame

@Suite("Shared rotation settings")
struct SharedRotationSettingsTests {
    @Test @MainActor func staleGUIAndHelperWritesPreserveEachOthersFields() throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        let helper = RotationEngine(storageURL: fixture.url)
        var settings = gui.settings
        settings.enabled = true
        settings.cadence = .hourly
        try gui.updateSettings(settings, now: fixture.now)
        helper.recordApplied(fixture.artwork("helper"), at: fixture.now)
        settings.pool = .saved
        try gui.updateSettings(settings, now: fixture.now)
        #expect(gui.history.map(\.artworkID) == ["helper"])
        helper.recordApplied(fixture.artwork("manual"), at: fixture.now.addingTimeInterval(1))
        try gui.refreshFromDisk()
        #expect(gui.settings.enabled)
        #expect(gui.settings.pool == .saved)
        #expect(gui.history.map(\.artworkID) == ["manual", "helper"])
    }

    @Test @MainActor func independentStalePreferenceChangesAreMerged() throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let first = RotationEngine(storageURL: fixture.url)
        let second = RotationEngine(storageURL: fixture.url)
        var enabled = first.settings
        enabled.enabled = true
        try first.updateSettings(enabled, now: fixture.now)
        var selectedPool = second.settings
        selectedPool.pool = .saved
        try second.updateSettings(selectedPool, now: fixture.now)
        #expect(second.settings.enabled)
        #expect(second.settings.pool == .saved)
        #expect(second.settingsRevision == 2)
    }

    @Test func concurrentHistoryAndPreferenceTransactionsDoNotLoseUpdates() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let first = RotationSharedStore(storageURL: fixture.url)
        let second = RotationSharedStore(storageURL: fixture.url)
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .everyHours
        settings.hours = 12
        let desired = settings
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try first.recordApplied("work-\(index)", at: fixture.now.addingTimeInterval(Double(index)))
                }
            }
            group.addTask { _ = try second.updateSettings(desired, now: fixture.now) }
            try await group.waitForAll()
        }
        let archive = try first.load()
        #expect(archive.settings == desired)
        #expect(Set(archive.state.history.map(\.artworkID)) == Set((0..<24).map { "work-\($0)" }))
        #expect(archive.state.nextDueDate == fixture.now.addingTimeInterval(12 * 3_600))
    }

    @Test func legacyVersionOneMigratesWithoutDeletingTheOriginalHistory() throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let old = fixture.root.appendingPathComponent("legacy.json")
        var settings = RotationSettings()
        settings.enabled = true
        settings.cadence = .hourly
        var state = RotationState()
        state.history = [RotationHistoryEntry(artworkID: "remembered", appliedAt: fixture.now)]
        state.lastSuccessAt = fixture.now
        state.nextDueDate = fixture.now.addingTimeInterval(3_600)
        struct Legacy: Encodable { let version = 1; let settings: RotationSettings; let state: RotationState }
        let data = try JSONEncoder().encode(Legacy(settings: settings, state: state))
        try data.write(to: old)
        let store = RotationSharedStore(storageURL: fixture.url, legacyURL: old)
        let migrated = try store.load()
        #expect(migrated.version == 2)
        #expect(migrated.settings == settings)
        #expect(migrated.state.history == state.history)
        #expect(migrated.state.nextDueDate == state.nextDueDate)
        #expect(try Data(contentsOf: old) == data)
        #expect(try RotationSharedStore(storageURL: fixture.url).load().version == 2)
    }

    @Test @MainActor func sharedLibraryProjectsSavedAndReusesTheDisplayFitSelector() throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        let landscape = fixture.artwork("wide", width: 6_000, height: 3_750)
        let portrait = fixture.artwork("portrait", width: 2_000, height: 4_000)
        try gui.publishLibrary(artworks: [landscape, portrait, landscape], savedIDs: [portrait.id])
        let helper = RotationEngine(storageURL: fixture.url)
        let library = try #require(helper.library)
        #expect(library.artworks.count == 2)
        let screen = ScreenProfile(id: "display", name: "Display", logicalWidth: 1_600, logicalHeight: 1_000,
            pixelWidth: 3_200, pixelHeight: 2_000, scale: 2, isMain: true)
        var settings = RotationSettings()
        settings.pool = .saved
        #expect(RotationCandidateSelector.select(library: library, settings: settings, screens: [screen]).map(\.id) == [portrait.id])
        settings.pool = .fitsScreen
        #expect(RotationCandidateSelector.select(library: library, settings: settings, screens: [screen]).map(\.id) == [landscape.id])
        try gui.publishLibrary(artworks: [landscape], savedIDs: [])
        try helper.refreshFromDisk()
        #expect(helper.library?.artworks.map(\.id) == [landscape.id])
        #expect(helper.library?.savedIDs.isEmpty == true)
    }

    @Test func kernelLeaseRejectsAnotherProcessAndReleasesAfterThatProcessExits() throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let lockURL = fixture.root.appendingPathComponent("execution.lock")
        let probe = try buildLockProbe(in: fixture.root)
        var owner = try ProcessFileLock.acquire(at: lockURL, blocking: false)
        try #require(owner != nil)
        let blocked = try withExtendedLifetime(owner) {
            try childLockProbe(probe, lockURL: lockURL, expectAcquired: false)
        }
        #expect(blocked == 0)
        owner = nil
        #expect(owner == nil)
        // The native child is killed without explicit unlock; the kernel must release its lock.
        let crashed = try childLockProbe(probe, lockURL: lockURL, expectAcquired: true, crash: true)
        #expect(crashed == 0)
        let recovered = try ProcessFileLock.acquire(at: lockURL, blocking: false)
        #expect(recovered != nil)
        withExtendedLifetime(recovered) {}
    }

    /// Compile a tiny native probe instead of forking a multithreaded Swift test runner.
    private func buildLockProbe(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("LockProbe.swift")
        let executable = directory.appendingPathComponent("LockProbe")
        try """
        import Darwin
        let args = CommandLine.arguments
        let fd = open(args[1], O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { exit(10) }
        let acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
        if acquired != (args[2] == "1") { exit(20) }
        if args[3] == "crash" { kill(getpid(), SIGKILL) }
        exit(0)
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "6", source.path, "-o", executable.path]
        let errors = Pipe()
        compiler.standardError = errors
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Native probe compilation failed"
            throw NSError(domain: "MuseFrameNativeProbe", code: Int(compiler.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return executable
    }

    private func childLockProbe(_ executable: URL, lockURL: URL, expectAcquired: Bool,
                                crash: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = [lockURL.path, expectAcquired ? "1" : "0", crash ? "crash" : "exit"]
        try process.run()
        process.waitUntilExit()
        if crash { return process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL ? 0 : -1 }
        return process.terminationStatus
    }
}

@Suite("Background rotation lifecycle")
struct BackgroundRotationTests {
    @Test @MainActor func automaticHintSeesArtworkAndAdvancedScheduleAfterBothCommits() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let engine = RotationEngine(storageURL: fixture.url)
        var settings = engine.settings
        settings.enabled = true; settings.cadence = .hourly
        try engine.updateSettings(settings, now: fixture.now)
        let artwork = fixture.artwork("ordered")
        let due = fixture.now.addingTimeInterval(3_600)
        var events: [String] = []
        var hintSawCompleteState = false
        let current = CurrentArtworkStore(directory: fixture.url.deletingLastPathComponent(), reloadTimelines: {
            events.append("hint")
            let state = try? RotationSharedStore(storageURL: fixture.url).load().state
            hintSawCompleteState = CurrentArtworkStorage.load(directory: fixture.url.deletingLastPathComponent())?.artworkID == artwork.id
                && state?.lastSuccessAt == due && state?.nextDueDate == due.addingTimeInterval(3_600)
        }, widgetReloadInterval: 0, now: { due })
        engine.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { current.snapshot?.artworkID },
            cachedOriginal: { _ in true }, apply: { artwork, _, _ in
                events.append("native")
                current.update(artwork, deferWidgetReload: true)
                #expect(current.storageError == nil)
                #expect(CurrentArtworkStorage.load(directory: fixture.url.deletingLastPathComponent())?.artworkID == artwork.id)
                events.append("current-committed")
            }, didCommitAutomatic: {
                events.append("schedule-committed")
                current.requestDeferredWidgetReload()
            }, scheduleAutomatically: false, publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { engine.stop() }
        await engine.checkDue(now: due)
        await engine.checkDue(now: due.addingTimeInterval(1))
        current.flushWidgetReload()
        #expect(events == ["native", "current-committed", "schedule-committed", "hint"])
        #expect(hintSawCompleteState)
    }

    @Test @MainActor func failedScheduleCommitRetriesOnlyPersistenceAndHintsOnceAfterRestartingSameEngine() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let engine = RotationEngine(storageURL: fixture.url)
        var settings = engine.settings
        settings.enabled = true; settings.cadence = .hourly
        try engine.updateSettings(settings, now: fixture.now)
        let artwork = fixture.artwork("already-applied")
        let due = fixture.now.addingTimeInterval(3_600)
        let durableBefore = try Data(contentsOf: fixture.url)
        var nativeWrites = 0, hints = 0
        let current = CurrentArtworkStore(directory: fixture.url.deletingLastPathComponent(),
            reloadTimelines: { hints += 1 }, widgetReloadInterval: 0, now: { due })
        engine.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { current.snapshot?.artworkID },
            cachedOriginal: { _ in true }, apply: { artwork, _, _ in
                nativeWrites += 1
                current.update(artwork, deferWidgetReload: true)
                // Native success and the DTO are durable, but the schedule path becomes unwritable.
                try FileManager.default.removeItem(at: fixture.url)
                try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
            }, didCommitAutomatic: { current.requestDeferredWidgetReload() }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        await engine.checkDue(now: due)
        await engine.checkDue(now: due.addingTimeInterval(1))
        #expect(nativeWrites == 1)
        #expect(hints == 0)
        #expect(engine.lastError != nil)
        current.flushWidgetReload()
        #expect(hints == 0)
        engine.stop()
        try FileManager.default.removeItem(at: fixture.url)
        try durableBefore.write(to: fixture.url, options: .atomic)
        await engine.checkDue(now: due.addingTimeInterval(2))
        #expect(hints == 0)
        engine.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { current.snapshot?.artworkID },
            cachedOriginal: { _ in true }, apply: { _, _, _ in nativeWrites += 1 },
            didCommitAutomatic: { current.requestDeferredWidgetReload() }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: due.addingTimeInterval(2))
        defer { engine.stop() }
        await engine.checkDue(now: due.addingTimeInterval(2))
        await engine.checkDue(now: due.addingTimeInterval(3))
        #expect(nativeWrites == 1)
        #expect(hints == 1)
        #expect(engine.lastError == nil)
        #expect(engine.state.lastSuccessAt == due)
        #expect(engine.nextDueDate == due.addingTimeInterval(3_600))
        #expect(engine.history.map(\.artworkID) == [artwork.id])
    }

    @Test @MainActor func failedArtworkPersistenceAdvancesNativeSuccessWithoutHintOrRepeatedApplication() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let engine = RotationEngine(storageURL: fixture.url)
        var settings = engine.settings
        settings.enabled = true; settings.cadence = .hourly
        try engine.updateSettings(settings, now: fixture.now)
        let invalidDirectory = fixture.root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: invalidDirectory)
        var writes = 0, hints = 0
        let current = CurrentArtworkStore(directory: invalidDirectory, reloadTimelines: { hints += 1 }, widgetReloadInterval: 0)
        let artwork = fixture.artwork("dto-failure")
        let due = fixture.now.addingTimeInterval(3_600)
        engine.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
            apply: { artwork, _, _ in writes += 1; current.update(artwork, deferWidgetReload: true) },
            didCommitAutomatic: { current.requestDeferredWidgetReload() }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { engine.stop() }
        await engine.checkDue(now: due)
        await engine.checkDue(now: due.addingTimeInterval(1))
        current.flushWidgetReload()
        #expect(writes == 1)
        #expect(hints == 0)
        #expect(current.storageError != nil)
        #expect(engine.state.lastSuccessAt == due)
        #expect(engine.nextDueDate == due.addingTimeInterval(3_600))
    }

    @Test @MainActor func stoppedWorkerDoesNotHintWhenAnAlreadyAppliedOperationReturnsLate() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let engine = RotationEngine(storageURL: fixture.url)
        var settings = engine.settings
        settings.enabled = true; settings.cadence = .hourly
        try engine.updateSettings(settings, now: fixture.now)
        var hints = 0, writes = 0
        let artwork = fixture.artwork("late-success")
        let current = CurrentArtworkStore(directory: fixture.url.deletingLastPathComponent(),
            reloadTimelines: { hints += 1 }, widgetReloadInterval: 0)
        let gate = BackgroundTestGate()
        engine.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { current.snapshot?.artworkID },
            cachedOriginal: { _ in true }, apply: { artwork, _, _ in
                writes += 1
                current.update(artwork, deferWidgetReload: true)
                await gate.suspend()
            }, didCommitAutomatic: { current.requestDeferredWidgetReload() }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        let task = Task { await engine.checkDue(now: fixture.now.addingTimeInterval(3_600)) }
        await gate.waitUntilEntered()
        engine.stop()
        await gate.release()
        await task.value
        current.flushWidgetReload()
        #expect(writes == 1)
        #expect(hints == 0)
        #expect(engine.history.map(\.artworkID) == [artwork.id])
    }

    @Test @MainActor func manualNextDoesNotInvokeAutomaticCompletionHint() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let engine = RotationEngine(storageURL: fixture.url)
        let artwork = fixture.artwork("manual")
        var writes = 0, completions = 0
        engine.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
            apply: { _, _, _ in writes += 1 }, didCommitAutomatic: { completions += 1 },
            scheduleAutomatically: false, publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { engine.stop() }
        await engine.nextArtwork()
        #expect(writes == 1)
        #expect(completions == 0)
        #expect(engine.history.map(\.artworkID) == [artwork.id])
    }

    @Test @MainActor func helperRestartDoesNotManufactureAnOnLaunchEvent() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        var settings = gui.settings
        settings.enabled = true
        settings.cadence = .onLaunch
        try gui.updateSettings(settings, now: fixture.now)
        let launch = UUID()
        try gui.publishLaunchEvent(id: launch, at: fixture.now)
        let works = [fixture.artwork("a"), fixture.artwork("b")]
        var current: String?
        var writes = 0
        let first = RotationEngine(storageURL: fixture.url)
        first.start(candidateProvider: { _ in works }, currentArtworkID: { current }, cachedOriginal: { _ in true },
            apply: { artwork, _, _ in current = artwork.id; writes += 1 }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        await first.checkDue(now: fixture.now, reason: .launch)
        first.stop()
        let restarted = RotationEngine(storageURL: fixture.url)
        restarted.start(candidateProvider: { _ in works }, currentArtworkID: { current }, cachedOriginal: { _ in true },
            apply: { artwork, _, _ in current = artwork.id; writes += 1 }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { restarted.stop() }
        await restarted.checkDue(now: fixture.now.addingTimeInterval(3_600), reason: .launch)
        #expect(writes == 1)
        try gui.publishLaunchEvent(id: launch, at: fixture.now)
        await restarted.checkDue(now: fixture.now.addingTimeInterval(3_601))
        #expect(writes == 1)
        try gui.publishLaunchEvent(at: fixture.now.addingTimeInterval(7_200))
        await restarted.checkDue(now: fixture.now.addingTimeInterval(7_200))
        #expect(writes == 2)
    }

    @Test @MainActor func retryDelaySurvivesHelperRestart() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        var settings = gui.settings
        settings.enabled = true
        settings.cadence = .hourly
        try gui.updateSettings(settings, now: fixture.now)
        let works = [fixture.artwork("failure")]
        var attempts = 0
        let first = RotationEngine(storageURL: fixture.url)
        first.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
            apply: { _, _, _ in attempts += 1; throw URLError(.notConnectedToInternet) }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        let due = fixture.now.addingTimeInterval(3_600)
        await first.checkDue(now: due)
        first.stop()
        let restarted = RotationEngine(storageURL: fixture.url)
        restarted.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
            apply: { _, _, _ in attempts += 1 }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { restarted.stop() }
        await restarted.checkDue(now: due.addingTimeInterval(1), reason: .launch)
        #expect(attempts == 1)
        #expect(restarted.state.retryNotBefore == due.addingTimeInterval(900))
        await restarted.checkDue(now: due.addingTimeInterval(900))
        #expect(attempts == 2)
    }

    @Test @MainActor func finalAuthorizationRejectsPauseEvenWhenNotificationIsLost() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        var settings = gui.settings
        settings.enabled = true
        settings.cadence = .hourly
        try gui.updateSettings(settings, now: fixture.now)
        let worker = RotationEngine(storageURL: fixture.url)
        let gate = BackgroundTestGate()
        let works = [fixture.artwork("pending")]
        var writes = 0
        worker.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
            apply: { _, request, _ in
                await gate.suspend()
                try worker.withAutomaticApplyAuthorization(settings: request) { writes += 1 }
            }, scheduleAutomatically: false, publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { worker.stop() }
        let task = Task { await worker.checkDue(now: fixture.now.addingTimeInterval(3_600)) }
        await gate.waitUntilEntered()
        settings.enabled = false
        try gui.updateSettings(settings, now: fixture.now)
        #expect(worker.settings.enabled) // No observer refreshed the worker's stale memory.
        await gate.release()
        await task.value
        #expect(writes == 0)
        #expect(worker.history.isEmpty)
        #expect(worker.state.retryNotBefore == nil)
        #expect(!worker.settings.enabled)
    }

    @Test @MainActor func changedRevisionRejectsOldDownloadAndNewConfigurationCanRun() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        var settings = gui.settings
        settings.enabled = true
        settings.cadence = .hourly
        try gui.updateSettings(settings, now: fixture.now)
        let worker = RotationEngine(storageURL: fixture.url)
        let gate = BackgroundTestGate()
        let works = [fixture.artwork("revision")]
        try gui.publishLibrary(artworks: works, savedIDs: [])
        var attempts = 0
        var modes: [WallpaperMode] = []
        worker.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
            apply: { _, request, _ in
                attempts += 1
                if attempts == 1 { await gate.suspend() }
                try worker.withAutomaticApplyAuthorization(settings: request) { modes.append(request.mode) }
            }, scheduleAutomatically: false, publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { worker.stop() }
        let due = fixture.now.addingTimeInterval(3_600)
        let task = Task { await worker.checkDue(now: due) }
        await gate.waitUntilEntered()
        settings.mode = .fit
        try gui.updateSettings(settings, now: due)
        await gate.release()
        await task.value
        #expect(modes.isEmpty)
        #expect(worker.state.retryNotBefore == nil)
        await worker.checkDue(now: due.addingTimeInterval(1))
        #expect(modes == [.fit])
        #expect(worker.history.count == 1)
    }

    @Test @MainActor func finalAuthorizationRejectsWithdrawnArtworkOrSavedMembership() async throws {
        for revocation in ["saved", "artwork", "missing"] {
            let fixture = RotationFixture()
            defer { fixture.remove() }
            let gui = RotationEngine(storageURL: fixture.url)
            let artwork = fixture.artwork("withdrawn")
            try gui.publishLibrary(artworks: [artwork], savedIDs: [artwork.id])
            var settings = gui.settings
            settings.enabled = true
            settings.cadence = .hourly
            settings.pool = .saved
            try gui.updateSettings(settings, now: fixture.now)
            let worker = RotationEngine(storageURL: fixture.url)
            let gate = BackgroundTestGate()
            var writes = 0
            worker.start(candidateProvider: { _ in [artwork] }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
                apply: { _, request, _ in
                    await gate.suspend()
                    try worker.withAutomaticApplyAuthorization(settings: request) { writes += 1 }
                }, scheduleAutomatically: false, publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
            defer { worker.stop() }
            let task = Task { await worker.checkDue(now: fixture.now.addingTimeInterval(3_600)) }
            await gate.waitUntilEntered()
            if revocation == "missing" {
                try FileManager.default.removeItem(at: RotationSharedStore(storageURL: fixture.url).libraryURL)
            } else {
                try gui.publishLibrary(artworks: revocation == "artwork" ? [] : [artwork], savedIDs: revocation == "artwork" ? [artwork.id] : [])
            }
            await gate.release()
            await task.value
            #expect(writes == 0)
            #expect(worker.history.isEmpty)
            #expect(worker.state.retryNotBefore == nil)
        }
    }

    @Test @MainActor func stoppedWorkerLeavesMissedScheduleAvailableToItsReplacement() async throws {
        let fixture = RotationFixture()
        defer { fixture.remove() }
        let gui = RotationEngine(storageURL: fixture.url)
        var settings = gui.settings
        settings.enabled = true
        settings.cadence = .hourly
        try gui.updateSettings(settings, now: fixture.now)
        let first = RotationEngine(storageURL: fixture.url)
        let gate = BackgroundTestGate()
        let works = [fixture.artwork("restart")]
        var writes = 0
        first.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in false },
            apply: { _, _, _ in await gate.suspend(); try Task.checkCancellation(); writes += 1 },
            scheduleAutomatically: false, publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        let task = Task { await first.checkDue(now: fixture.now.addingTimeInterval(3_600)) }
        await gate.waitUntilEntered()
        first.stop()
        await gate.release()
        await task.value
        let replacement = RotationEngine(storageURL: fixture.url)
        replacement.start(candidateProvider: { _ in works }, currentArtworkID: { nil }, cachedOriginal: { _ in true },
            apply: { _, _, _ in writes += 1 }, scheduleAutomatically: false,
            publishLaunchEvent: false, observeSharedChanges: false, now: fixture.now)
        defer { replacement.stop() }
        await replacement.checkDue(now: fixture.now.addingTimeInterval(20 * 3_600), reason: .launch)
        await replacement.checkDue(now: fixture.now.addingTimeInterval(20 * 3_600 + 1), reason: .wake)
        #expect(writes == 1)
        #expect(replacement.history.count == 1)
        #expect(replacement.nextDueDate == fixture.now.addingTimeInterval(21 * 3_600))
    }
}

private struct RotationFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuseFrame-SharedRotation-\(UUID().uuidString)")
    var url: URL { root.appendingPathComponent("shared/rotation-state.json") }
    let now = Date(timeIntervalSince1970: 1_792_579_600)
    func remove() { try? FileManager.default.removeItem(at: root) }
    func artwork(_ id: String, width: Int = 6_000, height: Int = 4_000) -> Artwork {
        let url = URL(string: "https://example.org/\(id).jpg")!
        return Artwork(id: id, source: .met, sourceID: id, titleOriginal: id, artistOriginal: "Artist", dateDisplay: "1900",
            museumName: "Museum", sourceURL: url,
            image: ArtworkImage(originalURL: url, thumbnailURL: url, width: width, height: height, license: "CC0 1.0"),
            isPublicDomain: true)
    }
}

private actor BackgroundTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        await withCheckedContinuation {
            continuation = $0
            for waiter in entered { waiter.resume() }
            entered.removeAll()
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered.append($0) }
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}
