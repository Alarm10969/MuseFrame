import Foundation
import WidgetKit

struct ArtworkEntry: TimelineEntry {
    let date: Date
    let snapshot: CurrentArtworkSnapshot?
}

/// A read-only projection of rotation-state.json, not another rotation engine or store.
struct WidgetRotationSnapshot: Decodable, Equatable, Sendable {
    let settings: RotationSchedule
    let lastSuccessAt: Date?
    let nextDueDate: Date?
    let retryNotBefore: Date?

    init(settings: RotationSchedule, lastSuccessAt: Date? = nil,
         nextDueDate: Date? = nil, retryNotBefore: Date? = nil) {
        self.settings = settings
        self.lastSuccessAt = lastSuccessAt
        self.nextDueDate = nextDueDate
        self.retryNotBefore = retryNotBefore
    }

    private enum CodingKeys: String, CodingKey { case version, settings, state }
    private struct TimingState: Decodable {
        let lastSuccessAt: Date?
        let nextDueDate: Date?
        let retryNotBefore: Date?
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw SharedStateError.invalidArchive }
        settings = try values.decode(RotationSchedule.self, forKey: .settings)
        let state = try values.decode(TimingState.self, forKey: .state)
        lastSuccessAt = state.lastSuccessAt
        nextDueDate = state.nextDueDate
        retryNotBefore = state.retryNotBefore
    }
}

enum WidgetTimelineSchedule {
    /// Give the helper time to finish native application and both atomic state commits.
    static let tolerance: TimeInterval = 60
    static let inactiveRefreshInterval: TimeInterval = 12 * 3_600
    static let overdueRefreshInterval: TimeInterval = 30 * 60
    static let unavailableRefreshInterval: TimeInterval = 3_600

    static func reloadDate(for rotation: WidgetRotationSnapshot?, now: Date,
                           calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard let rotation else { return now.addingTimeInterval(unavailableRefreshInterval) }
        guard rotation.settings.enabled, rotation.settings.cadence != .onLaunch else {
            // No periodic rotation is predicted for disabled or launch-only schedules.
            // A low-frequency metadata fallback also survives a missed refresh hint.
            return now.addingTimeInterval(inactiveRefreshInterval)
        }
        guard var due = rotation.nextDueDate ?? rotation.settings.nextDate(
            after: rotation.lastSuccessAt ?? now, calendar: calendar) else {
            return now.addingTimeInterval(unavailableRefreshInterval)
        }
        if let retry = rotation.retryNotBefore { due = max(due, retry) }
        let requested = due.addingTimeInterval(tolerance)
        // Waking after an overdue rotation must not return a date in the past or
        // continually request near-immediate timelines while the helper is delayed.
        return requested > now ? requested : now.addingTimeInterval(overdueRefreshInterval)
    }
}

struct WidgetTimelineSnapshot: Sendable {
    let date: Date
    let artwork: CurrentArtworkSnapshot?
    let rotation: WidgetRotationSnapshot?
    let reloadDate: Date

    var entry: ArtworkEntry { ArtworkEntry(date: date, snapshot: artwork) }

    /// Called afresh for every system request, for both Small and Medium.
    /// Hold the rotation lock while reading its schedule and the atomically
    /// replaced artwork manifest, without reentering the rotation store.
    /// No migration, network request or cached process-global artwork is involved.
    static func load(directory: URL? = nil, now: Date = .now,
                     calendar: Calendar = .autoupdatingCurrent) -> Self {
        let root = directory ?? MuseFrameSharedPaths.root
        var artwork: CurrentArtworkSnapshot?
        var rotation: WidgetRotationSnapshot?
        if let root {
            do {
                (artwork, rotation) = try ProcessFileLock.withLock(
                    at: root.appendingPathComponent("rotation-state.json.lock")) {
                    let rotation = try? readRotation(in: root)
                    return (CurrentArtworkStorage.load(directory: root), rotation)
                }
            } catch {
                // A broken schedule must not hide otherwise readable artwork.
                artwork = CurrentArtworkStorage.load(directory: root)
            }
        }
        return Self(date: now, artwork: artwork, rotation: rotation,
            reloadDate: WidgetTimelineSchedule.reloadDate(for: rotation, now: now, calendar: calendar))
    }

    private static func readRotation(in root: URL) throws -> WidgetRotationSnapshot {
        let url = root.appendingPathComponent("rotation-state.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 1_048_576 else {
            throw SharedStateError.invalidArchive
        }
        return try JSONDecoder().decode(WidgetRotationSnapshot.self, from: Data(contentsOf: url))
    }
}
