import SwiftUI

struct ArtworkDetailView: View {
    let artwork: Artwork
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var desktopPreview = false
    @State private var mode = WallpaperMode.fill
    @State private var selectedScreenID: String?
    @State private var guideExpanded = false

    private var screen: ScreenProfile? {
        previewScreens.first
    }
    private var previewScreens: [ScreenProfile] {
        let target: WallpaperTarget = selectedScreenID == "all" ? .all : selectedScreenID.map(WallpaperTarget.display) ?? .current
        return (try? target.resolve(in: model.screens, currentID: model.currentDisplayID)) ?? []
    }
    private var localThumbnail: URL? {
        guard let snapshot = model.currentStore.snapshot, snapshot.artworkID == artwork.id else { return nil }
        return CurrentArtworkStorage.thumbnailURL(for: snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).accessibilityLabel("关闭详情").keyboardShortcut(.cancelAction)
                Spacer()
                if desktopPreview {
                    Button { desktopPreview = false } label: { Label("作品全貌", systemImage: "photo") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 18)
            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 14) {
                    GeometryReader { geometry in
                        if desktopPreview {
                            HStack(spacing: 16) {
                                ForEach(previewScreens) { display in
                                    let width = max(1, min((geometry.size.width - CGFloat(max(0, previewScreens.count - 1)) * 16) / CGFloat(max(1, previewScreens.count)), (geometry.size.height - 44) * display.aspectRatio))
                                    VStack(spacing: 12) {
                                        ArtworkImageView(artwork: artwork, purpose: .detail, fill: mode != .fit, fallbackURL: localThumbnail)
                                            .frame(width: width, height: width / display.aspectRatio).background(.black).clipped()
                                        Text("\(display.name) · \(display.pixelWidth) × \(display.pixelHeight)")
                                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }.frame(width: geometry.size.width, height: geometry.size.height)
                        } else {
                            ArtworkImageView(artwork: artwork, purpose: .detail, fallbackURL: localThumbnail)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(artwork.displayTitle).font(.system(size: 29, design: .serif))
                            if artwork.titleZh != nil { Text(artwork.titleOriginal).font(.system(size: 14, design: .serif)).foregroundStyle(.secondary) }
                            artistAttribution
                            if let artistZh = artwork.artistZh, artistZh != artwork.artistOriginal {
                                Text(artwork.artistOriginal).font(.system(size: 12)).foregroundStyle(.tertiary)
                            }
                        }
                        HStack(spacing: 14) {
                            Button {
                                if !desktopPreview { desktopPreview = true }
                                else { Task { await model.setWallpaper(artwork, allScreens: selectedScreenID == "all", screenID: screen?.id, mode: mode) } }
                            } label: {
                                HStack { if model.isSettingWallpaper { ProgressView().controlSize(.small) }; Text(desktopPreview ? "设为壁纸" : "桌面预览") }
                            }.controlSize(.large).disabled(!artwork.isPublicDomain || model.isSettingWallpaper)
                                .accessibilityIdentifier("setWallpaper")
                            Button { model.toggleSaved(artwork) } label: {
                                Image(systemName: model.isSaved(artwork) ? "heart.fill" : "heart").font(.system(size: 17))
                            }.buttonStyle(.plain).accessibilityLabel(model.isSaved(artwork) ? "取消收藏" : "收藏")
                                .accessibilityIdentifier("saveArtwork")
                        }
                        if desktopPreview {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("显示方式", selection: $mode) {
                                    Text("Fill").tag(WallpaperMode.fill)
                                    Text("Fit").tag(WallpaperMode.fit)
                                    Text("Center Crop").tag(WallpaperMode.centerCrop)
                                }.pickerStyle(.segmented).labelsHidden()
                                if model.screens.count > 1 {
                                    Picker("预览显示器", selection: $selectedScreenID) {
                                        Text("当前显示器").tag(String?.none)
                                        ForEach(model.screens) { Text($0.name).tag(Optional($0.id)) }
                                        Text("所有显示器").tag(Optional("all"))
                                    }
                                }
                            }.font(.system(size: 12))
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            movementAttribution
                            if let medium = artwork.medium, !medium.isEmpty { Text(medium) }
                            if let dimensions = artwork.dimensions, !dimensions.isEmpty { Text(dimensions) }
                            Text(artwork.museumName)
                        }.font(.system(size: 12)).foregroundStyle(.secondary)

                        if artwork.guideStatus == .published, let guide = artwork.guide {
                            Text(introduction(guide)).font(.system(size: 14)).lineSpacing(6)
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            DisclosureGroup("导览", isExpanded: $guideExpanded) {
                                guideContent(guide).padding(.top, 18)
                            }.font(.system(size: 14, design: .serif)).accessibilityIdentifier("artworkGuide")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(artwork.isPublicDomain ? "Public Domain · \(artwork.image.license)" : artwork.image.license)
                            Text("元数据：\(artwork.metadataLicense)")
                            if let attribution = artwork.image.attribution { Text(attribution) }
                            Link("馆藏与资料来源 ↗", destination: artwork.sourceURL)
                            if let guide = artwork.guide, artwork.hasPublishedGuide {
                                Menu("导览来源") {
                                    ForEach(Array(Set(guide.sourceRefs)).sorted(by: { $0.absoluteString < $1.absoluteString }), id: \.self) { url in
                                        Link(url.host ?? "资料来源", destination: url)
                                    }
                                }.menuStyle(.borderlessButton).fixedSize()
                            }
                        }.font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 30)
                }.frame(width: 318)
            }.padding(.horizontal, 32).padding(.bottom, 30)
        }.frame(width: 1080, height: 720).background(MuseumStyle.canvas).tint(.primary)
        .alert("未能设置壁纸", isPresented: Binding(get: { model.wallpaperError != nil }, set: { if !$0 { model.wallpaperError = nil } })) {
            Button("重试") { Task { await model.retryWallpaper() } }
            Button("取消", role: .cancel) { model.wallpaperError = nil }
        } message: { Text(model.wallpaperError ?? "") }
    }

    private var artistAttribution: some View {
        HStack(spacing: 6) {
            if let artist = model.artHistory.artist(for: artwork.id) {
                NavigationLink { ArtistDetailView(artist: artist, model: model) } label: {
                    HStack(spacing: 5) { Text(artist.displayName); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                }.buttonStyle(.plain).accessibilityLabel("查看\(artist.displayName)的艺术家资料")
                    .accessibilityIdentifier("detailArtistHistory")
            } else { Text(artwork.displayArtist) }
            Text("· \(artwork.dateDisplay)")
        }.font(.system(size: 14)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var movementAttribution: some View {
        let movements = model.artHistory.movements(for: artwork.id)
        if movements.isEmpty {
            if artwork.movement != "Other", !artwork.movement.isEmpty { Text(artwork.movementZh ?? artwork.movement) }
        } else {
            ForEach(movements) { movement in
                Button { model.focusHistory(.movement(movement.id)) } label: {
                    HStack(spacing: 5) { Text(movement.displayName); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                }.buttonStyle(.plain).accessibilityLabel("在艺术史中查看\(movement.displayName)")
                    .accessibilityIdentifier("detailMovementHistory")
            }
        }
    }

    private func introduction(_ guide: ArtworkGuide) -> String {
        if let end = guide.summary30s.firstIndex(where: { "。！？".contains($0) }) { return String(guide.summary30s[...end]) }
        return guide.summary30s
    }

    private func guideContent(_ guide: ArtworkGuide) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !guide.lookAtPoints.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("今天看哪里").font(.system(size: 16, design: .serif))
                    ForEach(Array(guide.lookAtPoints.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").foregroundStyle(.tertiary)
                            Text(point)
                        }.font(.system(size: 13)).lineSpacing(5)
                    }
                }
            }
            if let text = guide.story { guideSection("作品故事", text: text) }
            if let text = guide.visualAnalysis { guideSection("怎么看", text: text) }
            if let text = guide.importance { guideSection("为什么重要", text: text) }
            if let text = guide.artistContext { guideSection("关于艺术家", text: text) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func guideSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, design: .serif))
            Text(text).font(.system(size: 13)).lineSpacing(6).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
