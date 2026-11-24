import Foundation

/// All processes resolve the same container. Signed builds never silently use a
/// per-process fallback when their App Group entitlement is missing.
enum MuseFrameSharedPaths {
    static let appGroupIdentifier = "group.io.museframe.shared"
    static let changeNotification = Notification.Name("io.museframe.shared-state-changed")

    static var root: URL? {
        #if MUSEFRAME_INSTALLED_BUILD
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        #elseif SWIFT_PACKAGE || MUSEFRAME_LOCAL_BUILD
        if let path = ProcessInfo.processInfo.environment["MUSEFRAME_VALIDATION_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("MuseFrame", isDirectory: true)
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        #endif
    }

    static func requireRoot() throws -> URL {
        guard let root else { throw SharedStateError.unavailableContainer }
        return root
    }

    static func url(_ relativePath: String) throws -> URL {
        try requireRoot().appendingPathComponent(relativePath)
    }

    static func notifyChange() {
        #if !MUSEFRAME_WIDGET
        DistributedNotificationCenter.default().postNotificationName(changeNotification,
            object: nil, userInfo: nil, deliverImmediately: true)
        #endif
    }
}

enum SharedStateError: LocalizedError {
    case unavailableContainer
    case busy
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .unavailableContainer: "共享目录不可用，请检查 MuseFrame 的 App Group 签名。"
        case .busy: "正在更换壁纸，请稍后重试。"
        case .invalidArchive: "共享轮换记录无法读取，已保留现有文件。"
        }
    }
}
