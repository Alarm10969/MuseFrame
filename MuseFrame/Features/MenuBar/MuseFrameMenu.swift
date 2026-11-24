import SwiftUI

struct MuseFrameMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private var current: Artwork? { model.currentArtwork }
    private var localThumbnail: URL? {
        model.currentStore.snapshot.flatMap { CurrentArtworkStorage.thumbnailURL(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let artwork = current {
                ArtworkImageView(artwork: artwork, purpose: .thumbnail, fallbackURL: localThumbnail).frame(width: 252, height: 142)
                Text(artwork.displayTitle).font(.system(size: 18, design: .serif)).lineLimit(2)
                Text("\(artwork.displayArtist) · \(artwork.dateDisplay)").font(.caption).foregroundStyle(.secondary)
                Button(model.isSaved(artwork) ? "取消收藏" : "收藏") { model.toggleSaved(artwork) }
            } else { Text("MuseFrame").font(.system(size: 20, design: .serif)) }
            Button {
                Task { await model.rotation.nextArtwork() }
            } label: {
                HStack { Text("下一幅"); if model.rotation.isRotating { ProgressView().controlSize(.mini) } }
            }.disabled(model.isSettingWallpaper || model.rotation.isRotating || model.rotationCandidates(model.rotation.settings).isEmpty)
            Button("打开 MuseFrame") {
                openWindow(id: "gallery")
                NSApp.activate(ignoringOtherApps: true)
                if let artwork = current { model.selectedArtwork = artwork }
            }
            if model.rotation.settings.enabled {
                Button("暂停自动轮换") { model.updateRotation { $0.enabled = false } }
            } else if !model.rotation.history.isEmpty {
                Button("恢复自动轮换") { model.updateRotation { $0.enabled = true } }
            }
            if let error = model.rotation.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack { SettingsLink { Text("设置…") }; Spacer(); Button("退出") { NSApp.terminate(nil) } }
        }.buttonStyle(.plain).padding(20).frame(width: 292)
    }
}
