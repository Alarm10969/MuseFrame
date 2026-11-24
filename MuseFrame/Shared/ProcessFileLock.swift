import Darwin
import Foundation

/// Advisory lock shared by the GUI and helper. The kernel releases it on crash.
/// Keep state transactions short; a separate nonblocking lease covers wallpaper work.
final class ProcessFileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(at url: URL, blocking: Bool = true) throws -> ProcessFileLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = url.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) != 0 {
            let failure = errno
            Darwin.close(descriptor)
            if !blocking && (failure == EWOULDBLOCK || failure == EAGAIN) { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return ProcessFileLock(descriptor: descriptor)
    }

    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        guard let lock = try acquire(at: url) else { throw SharedStateError.busy }
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
