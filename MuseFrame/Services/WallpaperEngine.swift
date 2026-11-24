import AppKit
import CryptoKit
import Foundation

enum WallpaperMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fill
    case fit
    case centerCrop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: "填满屏幕"
        case .fit: "显示完整作品"
        case .centerCrop: "居中裁切"
        }
    }
}

enum WallpaperError: LocalizedError {
    case rightsNotConfirmed
    case noDisplay
    case unavailableOffline
    case applyFailed(String)

    var errorDescription: String? {
        switch self {
        case .rightsNotConfirmed: "这幅作品的开放版权尚未确认，无法设为壁纸。"
        case .noDisplay: "没有可用的显示器，请重试。"
        case .unavailableOffline: "这幅作品的高清图片尚未缓存。"
        case .applyFailed(let reason): "系统未能应用壁纸：\(reason)"
        }
    }
}

enum WallpaperTarget: Hashable, Codable, Sendable {
    case current, main, all, display(String)

    func resolve(in screens: [ScreenProfile], currentID: String?) throws -> [ScreenProfile] {
        guard let fallback = ScreenProfile.preferred(in: screens) else { throw WallpaperError.noDisplay }
        let result: [ScreenProfile]
        switch self {
        case .all:
            var seen: Set<String> = []
            result = screens.sorted { $0.id < $1.id }.filter { seen.insert($0.id).inserted }
        case .main: result = [fallback]
        case .current:
            result = [currentID.flatMap { id in screens.first { $0.matchesIdentifier(id) } } ?? fallback]
        case .display(let id): result = [screens.first { $0.matchesIdentifier(id) } ?? fallback]
        }
        return result
    }
}

struct WallpaperReceipt: Sendable {
    let displayImages: [String: URL]
    let localImageURL: URL
    var displayIDs: [String] { displayImages.keys.sorted() }
}

/// A render belongs to the display geometry that requested it. Never commit stale crops after wake/unplug.
enum WallpaperDisplayValidation {
    static func validate(prepared: [ScreenProfile], connected: [ScreenProfile]) throws {
        guard !prepared.isEmpty else { throw WallpaperError.noDisplay }
        for screen in prepared {
            guard let live = connected.first(where: { $0.id == screen.id }),
                  live.pixelWidth == screen.pixelWidth, live.pixelHeight == screen.pixelHeight else {
                throw WallpaperError.applyFailed("显示器配置已变化，请重新预览后重试。")
            }
        }
    }
}

@MainActor protocol DesktopImageApplying {
    func currentURL(for screen: NSScreen) -> URL?
    func currentOptions(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any]
    func apply(_ file: URL, to screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws
}

@MainActor struct SystemDesktopImageApplier: DesktopImageApplying {
    func currentURL(for screen: NSScreen) -> URL? { NSWorkspace.shared.desktopImageURL(for: screen) }
    func currentOptions(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any] { NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:] }
    func apply(_ file: URL, to screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
    }
}

/// The caller can validate shared enabled/revision state immediately before a synchronous desktop transaction.
typealias WallpaperApplyAuthorization = @MainActor (_ operation: () throws -> Void) throws -> Void

/// Transaction logic works with stable IDs so a multi-display failure is testable without real hardware.
@MainActor enum WallpaperApplicationTransaction {
    static func perform(displayIDs: [String], apply: (String) throws -> Void, rollback: (String) throws -> Void) throws {
        guard !displayIDs.isEmpty else { throw WallpaperError.noDisplay }
        var attempted: [String] = []
        do {
            for id in displayIDs {
                try Task.checkCancellation()
                attempted.append(id)
                try apply(id)
            }
        } catch {
            var restoreErrors: [String] = []
            // A setter may fail after touching its target, so include that display in recovery.
            for id in attempted.reversed() {
                do { try rollback(id) }
                catch { restoreErrors.append(error.localizedDescription) }
            }
            if error is CancellationError, restoreErrors.isEmpty { throw CancellationError() }
            throw WallpaperError.applyFailed(([error.localizedDescription] + restoreErrors).joined(separator: "；"))
        }
    }
}

@MainActor
struct WallpaperEngine {
    var cache = ImageCache.shared
    var applier: any DesktopImageApplying = SystemDesktopImageApplier()
    /// Test overrides use an isolated directory; production always resolves the shared root.
    var appliedDirectory: URL? = nil

    @discardableResult
    func set(_ artwork: Artwork, on screens: [NSScreen], mode: WallpaperMode = .fill, allowDownload: Bool = true,
             authorizeApply: WallpaperApplyAuthorization? = nil) async throws -> WallpaperReceipt {
        guard artwork.isPublicDomain, !artwork.image.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WallpaperError.rightsNotConfirmed
        }
        guard !screens.isEmpty else { throw WallpaperError.noDisplay }
        let requested = Set(screens.compactMap(Self.identifier(of:)))
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let cached: URL
        if let applied = existingDesktopImage(for: artwork) { cached = applied }
        else if let existing = await cache.cachedFileURL(for: artwork, purpose: .wallpaper) { cached = existing }
        else if allowDownload { cached = try await ImageCache.stageWallpaper(artwork.image.originalURL, in: staging) }
        else { throw WallpaperError.unavailableOffline }
        try Task.checkCancellation()
        // Reconcile targets after async I/O: hot unplug must not leave an obsolete NSScreen handle.
        let connected = NSScreen.screens
        var targets = connected.filter { Self.identifier(of: $0).map(requested.contains) == true }
        if targets.isEmpty, let fallback = ScreenProfile.preferred(in: ScreenProfile.current()),
           let screen = connected.first(where: { Self.identifier(of: $0) == fallback.id }) {
            targets = [screen]
        }
        guard !targets.isEmpty else { throw WallpaperError.noDisplay }
        let targetIDs = Set(targets.compactMap(Self.identifier(of:)))
        let preparedProfiles = ScreenProfile.current().filter { targetIDs.contains($0.id) }
        // Desktop files outlive the disposable image cache, including after relaunch.
        let previousOriginal = existingDesktopImage(for: artwork)
        var created = Set<URL>()
        var committed = false
        var beganApplying = false
        defer {
            if !committed {
                let inUse = beganApplying ? Set(NSScreen.screens.compactMap { applier.currentURL(for: $0)?.standardizedFileURL }) : []
                for url in created where !inUse.contains(url.standardizedFileURL) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let file = try prepareDesktopImage(cached, artwork: artwork, directory: appliedDirectory)
        if previousOriginal == nil { created.insert(file) }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: mode == .fill,
            .fillColor: NSColor.black
        ]
        var prepared: [String: URL] = [:]
        for screen in targets {
            guard let id = Self.identifier(of: screen) else { throw WallpaperError.noDisplay }
            if mode == .centerCrop {
                guard let profile = ScreenProfile.current().first(where: { $0.id == id }) else { throw WallpaperError.noDisplay }
                let crop = try await Task.detached(priority: .userInitiated) {
                    try DesktopCropRenderer.renderTrackingCreation(file, width: profile.pixelWidth, height: profile.pixelHeight)
                }.value
                prepared[id] = crop.url
                if crop.created { created.insert(crop.url) }
            } else { prepared[id] = file }
        }
        let transaction = {
            guard !committed else { throw CocoaError(.userCancelled) }
            try Task.checkCancellation()
            try WallpaperDisplayValidation.validate(prepared: preparedProfiles, connected: ScreenProfile.current())
            // Rendering may suspend. Use fresh NSScreen handles only after validating the prepared geometry.
            let liveTargets = NSScreen.screens.filter { Self.identifier(of: $0).map(targetIDs.contains) == true }
            guard liveTargets.count == targetIDs.count else { throw WallpaperError.noDisplay }
            // Capture original URLs/options inside the same authorization window as all native writes.
            let previous = liveTargets.compactMap { screen -> (String, NSScreen, URL?, [NSWorkspace.DesktopImageOptionKey: Any])? in
                guard let id = Self.identifier(of: screen) else { return nil }
                return (id, screen, applier.currentURL(for: screen), applier.currentOptions(for: screen))
            }
            let byID = Dictionary(previous.map { ($0.0, $0) }, uniquingKeysWith: { first, _ in first })
            beganApplying = true
            try WallpaperApplicationTransaction.perform(displayIDs: previous.map(\.0), apply: { id in
                guard let entry = byID[id], let image = prepared[id] else { throw WallpaperError.noDisplay }
                try applier.apply(image, to: entry.1, options: options)
            }, rollback: { id in
                guard let entry = byID[id], let url = entry.2 else {
                    throw WallpaperError.applyFailed("原壁纸不可用，无法恢复显示器 \(id)。")
                }
                try applier.apply(url, to: entry.1, options: entry.3)
            })
            committed = true
        }
        if let authorizeApply { try authorizeApply(transaction) }
        else { try transaction() }
        guard committed else { throw CancellationError() }
        let mainID = ScreenProfile.persistentIdentifier(for: CGMainDisplayID())
        return WallpaperReceipt(displayImages: prepared,
            localImageURL: prepared[mainID] ?? prepared.sorted { $0.key < $1.key }.first?.value ?? file)
    }

    static func identifier(of screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return ScreenProfile.persistentIdentifier(for: number.uint32Value)
    }

    func existingDesktopImage(for artwork: Artwork, directory: URL? = nil) -> URL? {
        guard let directory = directory ?? appliedDirectory ?? MuseFrameSharedPaths.root?.appendingPathComponent("AppliedWallpapers") else { return nil }
        return Self.retainedOriginal(artwork.image.originalURL, in: directory)
    }

    nonisolated static func retainedOriginal(_ source: URL, in directory: URL) -> URL? {
        let key = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let suffix = source.pathExtension.lowercased()
        for ext in [suffix, "jpg", "jpeg", "png", "heic", "tif", "tiff", "webp"] where !ext.isEmpty {
            let url = directory.appendingPathComponent(key).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Kept apart from applying the desktop, so persistence can be verified without changing it.
    /// These originals are retained: the workspace API cannot enumerate references from other Spaces.
    func prepareDesktopImage(_ cached: URL, artwork: Artwork, directory: URL? = nil) throws -> URL {
        let target = try directory ?? appliedDirectory ?? MuseFrameSharedPaths.url("AppliedWallpapers")
        return try Self.persistDesktopImage(cached, originalURL: artwork.image.originalURL, in: target)
    }

    /// Foundation-only file preparation can race safely between the GUI and helper.
    nonisolated static func persistDesktopImage(_ cached: URL, originalURL: URL, in target: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(originalURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let output = target.appendingPathComponent(key).appendingPathExtension(cached.pathExtension)
        guard !manager.fileExists(atPath: output.path) else { return output }
        let temporary = target.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: cached, to: temporary)
        do { try manager.moveItem(at: temporary, to: output) }
        catch {
            // Another process may finish the same immutable source while this copy is being prepared.
            let existing = try? manager.attributesOfItem(atPath: output.path)
            let copied = try? manager.attributesOfItem(atPath: temporary.path)
            guard existing?[.type] as? FileAttributeType == .typeRegular,
                  let size = existing?[.size] as? NSNumber, size.int64Value > 0,
                  size == copied?[.size] as? NSNumber else { throw error }
        }
        return output
    }
}
