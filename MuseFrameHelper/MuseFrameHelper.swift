import AppKit
import Foundation

@MainActor final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var runtime: BackgroundRotationRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let worker = try BackgroundRotationRuntime()
            runtime = worker
            let once = CommandLine.arguments.contains("--once")
            try worker.start(scheduleAutomatically: !once)
            if once { Task { await worker.checkOnce(); NSApp.terminate(nil) } }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { runtime?.stop() }
}

@main enum MuseFrameHelper {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check") {
            do {
                let root = try MuseFrameSharedPaths.requireRoot()
                let store = RotationSharedStore(storageURL: root.appendingPathComponent("rotation-state.json"))
                let archive = try store.load()
                let library = try store.loadLibrary()
                let current = try CurrentArtworkStorage.read(directory: root)
                let report: [String: Any] = [
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    "rotationEnabled": archive.settings.enabled,
                    "settingsRevision": archive.settingsRevision, "artworkCount": library?.artworks.count ?? 0,
                    "savedCount": library?.savedIDs.count ?? 0, "currentArtworkID": current?.artworkID ?? "",
                    "displayCount": ScreenProfile.current().count, "mode": "read-only"]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = HelperDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
