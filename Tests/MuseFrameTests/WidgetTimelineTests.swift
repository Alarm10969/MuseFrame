import Foundation
import Testing
@testable import MuseFrame

@Suite("Widget timeline fallback")
struct WidgetTimelineTests {
    @Test func persistedDueDateWinsOverRecalculationAndTimeZoneChanges() throws {
        let now = date("2026-10-27T00:00:00Z")
        let due = now.addingTimeInterval(9_000)
        let rotation = WidgetRotationSnapshot(
            settings: RotationSchedule(enabled: true, cadence: .daily, dailyMinute: 8 * 60),
            lastSuccessAt: now.addingTimeInterval(-86_400), nextDueDate: due
        )
        let shanghai = try calendar("Asia/Shanghai")
        let newYork = try calendar("America/New_York")
        #expect(WidgetTimelineSchedule.reloadDate(for: rotation, now: now, calendar: shanghai)
            == due.addingTimeInterval(60))
        #expect(WidgetTimelineSchedule.reloadDate(for: rotation, now: now, calendar: newYork)
            == due.addingTimeInterval(60))
    }

    @Test func missingHourlyDueUsesLastSuccessRatherThanTheTimelineRequestTime() {
        let now = date("2026-10-27T09:40:00Z")
        let last = date("2026-10-27T09:00:00Z")
        let settings = RotationSchedule(enabled: true, cadence: .hourly)
        let restored = WidgetRotationSnapshot(settings: settings, lastSuccessAt: last)
        #expect(WidgetTimelineSchedule.reloadDate(for: restored, now: now)
            == date("2026-10-27T10:01:00Z"))
        let firstRun = WidgetRotationSnapshot(settings: settings)
        #expect(WidgetTimelineSchedule.reloadDate(for: firstRun, now: now)
            == date("2026-10-27T10:41:00Z"))
    }

    @Test(arguments: [1, 6, 12, 24])
    func customIntervalsScheduleAfterTheLastActualRotation(hours: Int) {
        let last = date("2026-10-27T09:00:00Z")
        let now = last.addingTimeInterval(15 * 60)
        let settings = RotationSchedule(enabled: true, cadence: .everyHours, hours: hours)
        let expectedDue = last.addingTimeInterval(Double(hours) * 3_600)
        #expect(settings.nextDate(after: last) == expectedDue)
        #expect(WidgetTimelineSchedule.reloadDate(
            for: WidgetRotationSnapshot(settings: settings, lastSuccessAt: last), now: now
        ) == expectedDue.addingTimeInterval(60))
    }

    @Test func dailyFallbackCrossesMidnightAndUsesTheSuppliedTimeZone() throws {
        let now = date("2026-10-27T15:30:00Z") // 23:30 in Shanghai.
        let settings = RotationSchedule(enabled: true, cadence: .daily, dailyMinute: 15)
        let rotation = WidgetRotationSnapshot(settings: settings, lastSuccessAt: now)
        #expect(WidgetTimelineSchedule.reloadDate(for: rotation, now: now,
            calendar: try calendar("Asia/Shanghai")) == date("2026-10-27T16:16:00Z"))
        #expect(WidgetTimelineSchedule.reloadDate(for: rotation, now: now,
            calendar: try calendar("America/New_York")) == date("2026-10-28T04:16:00Z"))
    }

    @Test func dailyFallbackPreservesExistingSpringAndAutumnDSTSemantics() throws {
        let newYork = try calendar("America/New_York")
        let spring = date("2026-03-08T00:00:00-05:00")
        let missingTime = RotationSchedule(enabled: true, cadence: .daily, dailyMinute: 2 * 60 + 30)
        let springDue = try #require(missingTime.nextDate(after: spring, calendar: newYork))
        #expect(springDue == date("2026-03-08T03:00:00-04:00"))
        #expect(WidgetTimelineSchedule.reloadDate(
            for: WidgetRotationSnapshot(settings: missingTime, lastSuccessAt: spring),
            now: spring, calendar: newYork
        ) == springDue.addingTimeInterval(60))

        let autumn = date("2026-11-01T00:00:00-04:00")
        let repeatedTime = RotationSchedule(enabled: true, cadence: .daily, dailyMinute: 90)
        let autumnDue = try #require(repeatedTime.nextDate(after: autumn, calendar: newYork))
        #expect(autumnDue == date("2026-11-01T01:30:00-04:00"))
        #expect(WidgetTimelineSchedule.reloadDate(
            for: WidgetRotationSnapshot(settings: repeatedTime, lastSuccessAt: autumn),
            now: autumn, calendar: newYork
        ) == autumnDue.addingTimeInterval(60))
        #expect(repeatedTime.nextDate(after: date("2026-11-01T02:00:00-05:00"), calendar: newYork)
            == date("2026-11-02T01:30:00-05:00"))
    }

    @Test func sharedScheduleAndHelperPlannerRemainEquivalentForAllCadences() throws {
        let now = date("2026-03-08T05:00:00Z")
        let newYork = try calendar("America/New_York")
        for cadence in RotationCadence.allCases {
            var settings = RotationSettings()
            settings.enabled = true
            settings.cadence = cadence
            settings.hours = 12
            settings.dailyMinute = 2 * 60 + 30
            let shared = RotationSchedule(enabled: settings.enabled, cadence: settings.cadence,
                hours: settings.hours, dailyMinute: settings.dailyMinute)
            #expect(shared.nextDate(after: now, calendar: newYork)
                == RotationPlanner().nextDate(after: now, settings: settings, calendar: newYork))
        }
    }

    @Test func missedRotationAfterSleepUsesBoundedFutureReloadsWithoutInventingCatchUpEntries() {
        let now = date("2026-10-28T09:00:00Z")
        let stale = WidgetRotationSnapshot(
            settings: RotationSchedule(enabled: true, cadence: .hourly),
            lastSuccessAt: now.addingTimeInterval(-9 * 3_600),
            nextDueDate: now.addingTimeInterval(-8 * 3_600)
        )
        let first = WidgetTimelineSchedule.reloadDate(for: stale, now: now)
        #expect(first == now.addingTimeInterval(1_800))
        // If the Helper is still unable to apply, the next system request must not
        // return a past policy date or start a seconds-long reload loop.
        #expect(WidgetTimelineSchedule.reloadDate(for: stale, now: first)
            == first.addingTimeInterval(1_800))
        let missingDue = WidgetRotationSnapshot(settings: stale.settings, lastSuccessAt: stale.lastSuccessAt)
        #expect(WidgetTimelineSchedule.reloadDate(for: missingDue, now: now) == first)
    }

    @Test func toleranceHandlesJustCompletedAndExactlyExpiredDueDates() {
        let now = date("2026-10-27T09:00:00Z")
        let settings = RotationSchedule(enabled: true, cadence: .hourly)
        let withinTolerance = WidgetRotationSnapshot(settings: settings,
            nextDueDate: now.addingTimeInterval(-30))
        #expect(WidgetTimelineSchedule.reloadDate(for: withinTolerance, now: now)
            == now.addingTimeInterval(30))
        let elapsedTolerance = WidgetRotationSnapshot(settings: settings,
            nextDueDate: now.addingTimeInterval(-60))
        #expect(WidgetTimelineSchedule.reloadDate(for: elapsedTolerance, now: now)
            == now.addingTimeInterval(1_800))
    }

    @Test func retryBoundaryCanDelayAnOverdueRotationButCannotPullAFutureDueDateEarlier() {
        let now = date("2026-10-27T09:00:00Z")
        let settings = RotationSchedule(enabled: true, cadence: .hourly)
        let retry = now.addingTimeInterval(15 * 60)
        let waiting = WidgetRotationSnapshot(settings: settings,
            nextDueDate: now.addingTimeInterval(-300), retryNotBefore: retry)
        #expect(WidgetTimelineSchedule.reloadDate(for: waiting, now: now)
            == retry.addingTimeInterval(60))
        let due = now.addingTimeInterval(3_600)
        let future = WidgetRotationSnapshot(settings: settings, nextDueDate: due, retryNotBefore: retry)
        #expect(WidgetTimelineSchedule.reloadDate(for: future, now: now) == due.addingTimeInterval(60))
    }

    @Test func disabledAndLaunchOnlySettingsIgnoreOldTimedStateAndUseLowFrequencyMetadataFallback() {
        let now = date("2026-10-27T09:00:00Z")
        for settings in [
            RotationSchedule(enabled: false, cadence: .hourly),
            RotationSchedule(enabled: true, cadence: .onLaunch)
        ] {
            let stale = WidgetRotationSnapshot(settings: settings, lastSuccessAt: now,
                nextDueDate: now.addingTimeInterval(60), retryNotBefore: now.addingTimeInterval(120))
            #expect(settings.nextDate(after: now) == nil)
            #expect(WidgetTimelineSchedule.reloadDate(for: stale, now: now)
                == now.addingTimeInterval(12 * 3_600))
        }
    }

    @Test func nextLoadReadsTheDailyHelpersCommittedArtworkAndScheduleAfterRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let due = date("2026-10-27T08:00:00Z")
        var initial = RotationArchive()
        initial.settings.enabled = true
        initial.settings.cadence = .daily
        initial.settings.dailyMinute = 8 * 60
        initial.state.lastSuccessAt = due.addingTimeInterval(-86_400)
        initial.state.nextDueDate = due
        let archiveURL = directory.appendingPathComponent("rotation-state.json")
        try JSONEncoder().encode(initial).write(to: archiveURL, options: .atomic)
        let oldArtwork = artwork("met-before", at: due.addingTimeInterval(-86_400))
        try CurrentArtworkStorage.save(oldArtwork, directory: directory)
        let before = WidgetTimelineSnapshot.load(directory: directory, now: due.addingTimeInterval(-120))
        #expect(before.artwork == oldArtwork)
        #expect(before.entry.snapshot == oldArtwork)
        #expect(before.reloadDate == due.addingTimeInterval(60))

        // Simulate the successful native-write boundary: the atomic artwork commit
        // precedes the Helper's persisted success/next-due transaction.
        let store = RotationSharedStore(storageURL: archiveURL)
        let token = try #require(try store.load().dueToken(at: due))
        let appliedAt = due.addingTimeInterval(5)
        let newArtwork = artwork("met-after", at: appliedAt)
        try CurrentArtworkStorage.save(newArtwork, directory: directory)
        let finished = try store.finishAutomatic(newArtwork.artworkID, token: token, at: appliedAt)
        let nextDue = try #require(finished.state.nextDueDate)
        let requestedAt = appliedAt.addingTimeInterval(120)
        let after = WidgetTimelineSnapshot.load(directory: directory, now: requestedAt)
        #expect(after.date == requestedAt)
        #expect(after.artwork == newArtwork)
        #expect(after.entry.date == requestedAt)
        #expect(after.entry.snapshot == newArtwork)
        #expect(after.entry.snapshot?.deepLink?.absoluteString == "museframe://artwork/met-after")
        #expect(after.rotation?.lastSuccessAt == appliedAt)
        #expect(after.rotation?.nextDueDate == nextDue)
        #expect(after.reloadDate == nextDue.addingTimeInterval(60))
        #expect(before.artwork == oldArtwork)

        // A new caller (as after an extension/Helper restart) rereads the same
        // persisted state without replaying a rotation or relying on a reload hint.
        let restarted = WidgetTimelineSnapshot.load(directory: directory, now: requestedAt.addingTimeInterval(1))
        #expect(restarted.artwork == newArtwork)
        #expect(restarted.entry.snapshot == newArtwork)
        #expect(restarted.rotation == after.rotation)
        #expect(try store.load().state.history.map(\.artworkID) == [newArtwork.artworkID])
    }

    @Test func missingDamagedAndUnsupportedRotationArchivesPreserveArtworkAndUseSafeFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-27T09:00:00Z")
        let current = artwork("met-current", at: now)
        try CurrentArtworkStorage.save(current, directory: directory)
        let rotationURL = directory.appendingPathComponent("rotation-state.json")
        let missing = WidgetTimelineSnapshot.load(directory: directory, now: now)
        #expect(missing.artwork == current)
        #expect(missing.rotation == nil)
        #expect(missing.reloadDate == now.addingTimeInterval(3_600))
        #expect(!FileManager.default.fileExists(atPath: rotationURL.path))

        var unsupported = RotationArchive()
        unsupported.version = 999
        unsupported.settings.enabled = true
        unsupported.state.nextDueDate = now.addingTimeInterval(60)
        for data in [Data("{unfinished".utf8), try JSONEncoder().encode(unsupported)] {
            try data.write(to: rotationURL, options: .atomic)
            let snapshot = WidgetTimelineSnapshot.load(directory: directory, now: now)
            #expect(snapshot.artwork == current)
            #expect(snapshot.rotation == nil)
            #expect(snapshot.reloadDate == now.addingTimeInterval(3_600))
            #expect(try Data(contentsOf: rotationURL) == data)
        }
    }

    @Test func damagedArtworkDoesNotDiscardAValidScheduleOrRetainPreviousArtwork() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-27T09:00:00Z")
        var archive = RotationArchive()
        archive.settings.enabled = true
        archive.settings.cadence = .hourly
        archive.state.nextDueDate = now.addingTimeInterval(3_600)
        try JSONEncoder().encode(archive).write(
            to: directory.appendingPathComponent("rotation-state.json"), options: .atomic)
        try CurrentArtworkStorage.save(artwork("met-before", at: now), directory: directory)
        #expect(WidgetTimelineSnapshot.load(directory: directory, now: now).artwork?.artworkID == "met-before")
        try Data("{damaged".utf8).write(to: directory.appendingPathComponent("current-artwork.json"), options: .atomic)
        let snapshot = WidgetTimelineSnapshot.load(directory: directory, now: now)
        #expect(snapshot.artwork == nil)
        #expect(snapshot.rotation?.nextDueDate == archive.state.nextDueDate)
        #expect(snapshot.reloadDate == now.addingTimeInterval(3_660))
    }

    @Test func readingLegacyRotationIsReadOnlyAndDoesNotPerformAWidgetSideMigration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-10-27T09:00:00Z")
        var legacy = RotationArchive()
        legacy.version = 1
        legacy.settings.enabled = true
        legacy.settings.cadence = .everyHours
        legacy.settings.hours = 6
        legacy.state.lastSuccessAt = now
        legacy.state.nextDueDate = now.addingTimeInterval(6 * 3_600)
        let bytes = try JSONEncoder().encode(legacy)
        let file = directory.appendingPathComponent("rotation-state.json")
        try bytes.write(to: file, options: .atomic)
        let snapshot = WidgetTimelineSnapshot.load(directory: directory, now: now)
        #expect(snapshot.rotation?.nextDueDate == legacy.state.nextDueDate)
        #expect(snapshot.reloadDate == now.addingTimeInterval(6 * 3_600 + 60))
        #expect(try Data(contentsOf: file) == bytes)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        return calendar
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseFrame-WidgetTimeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func artwork(_ id: String, at date: Date) -> CurrentArtworkSnapshot {
        CurrentArtworkSnapshot(artworkID: id, title: "作品 \(id)", artist: "Artist", dateDisplay: "1889",
            summary30s: "已有的作品简介。", thumbnailURL: nil, updatedAt: date)
    }
}
