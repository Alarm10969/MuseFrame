import Foundation

/// Local opt-in development measurements. No collection or network transmission.
/// Ready/appearance events describe application work, not compositor presentation time.
final class PerformanceDiagnostics: @unchecked Sendable {
    private static let shared = PerformanceDiagnostics()
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private let destination: URL?
    private var recorded: Set<String> = []

    private init() {
        if let path = ProcessInfo.processInfo.environment["MUSEFRAME_PERFORMANCE_LOG"], !path.isEmpty {
            destination = URL(fileURLWithPath: path)
        } else { destination = nil }
    }

    static func mark(_ event: String, once: Bool = false, fields: [String: String] = [:]) {
        shared.record(event, once: once, fields: fields)
    }

    private func record(_ event: String, once: Bool, fields: [String: String]) {
        guard let destination else { return }
        lock.lock()
        defer { lock.unlock() }
        if once && !recorded.insert(event).inserted { return }
        let value: [String: Any] = ["event": event, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "unixTime": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier, "fields": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
        } catch { /* Diagnostics must never interrupt browsing or wallpaper work. */ }
    }
}
