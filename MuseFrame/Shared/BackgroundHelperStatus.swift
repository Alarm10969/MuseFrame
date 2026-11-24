import Darwin
import Foundation

/// A liveness receipt, separate from ServiceManagement's registration/approval status.
struct BackgroundHelperStatus: Codable, Equatable, Sendable {
    let processID: Int32
    let sessionID: UUID
    let checkedAt: Date
    let version: String
    let lastError: String?

    func isAlive(at now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        guard age >= -10, age < 120, processID > 0 else { return false }
        return kill(processID, 0) == 0 || errno == EPERM
    }

    static func read(directory: URL? = nil) -> Self? {
        guard let root = directory ?? MuseFrameSharedPaths.root,
              let data = try? Data(contentsOf: root.appendingPathComponent("helper-status.json")),
              data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(directory: URL? = nil) throws {
        let root = try directory ?? MuseFrameSharedPaths.requireRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("helper-status.json"), options: .atomic)
    }
}
