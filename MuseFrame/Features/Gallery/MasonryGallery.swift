import SwiftUI

struct MasonryGallery: View {
    let artworks: [Artwork]
    let width: CGFloat
    @Bindable var model: AppModel

    private var columnCount: Int { max(3, min(6, Int((width + MuseumStyle.gap) / 252))) }
    private var columnWidth: CGFloat { max(1, (width - CGFloat(columnCount - 1) * MuseumStyle.gap) / CGFloat(columnCount)) }
    private var columns: [[Artwork]] {
        var groups = Array(repeating: [Artwork](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)
        for artwork in artworks {
            let index = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            groups[index].append(artwork)
            heights[index] += columnWidth / max(artwork.aspectRatio, 0.15) + 76
        }
        return groups
    }

    var body: some View {
        HStack(alignment: .top, spacing: MuseumStyle.gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(column) { artwork in ArtworkTile(artwork: artwork, width: columnWidth, model: model) }
                }.frame(width: columnWidth)
            }
        }.frame(width: width, alignment: .topLeading)
    }
}

struct ArtworkTile: View {
    let artwork: Artwork
    let width: CGFloat
    @Bindable var model: AppModel
    @State private var hovering = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { model.selectedArtwork = artwork } label: {
                ArtworkImageView(artwork: artwork, purpose: .thumbnail,
                    pixelSize: Int((width * displayScale * max(1, 1 / artwork.aspectRatio)).rounded(.up)))
                    .frame(width: width, height: width / max(artwork.aspectRatio, 0.15)).clipped()
                    .brightness(hovering ? 0.025 : 0)
            }.buttonStyle(.plain).accessibilityLabel("\(artwork.displayTitle)，\(artwork.displayArtist)")
            .accessibilityAction(named: model.isSaved(artwork) ? "取消收藏" : "收藏") { model.toggleSaved(artwork) }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { model.toggleSaved(artwork) } label: {
                        Image(systemName: model.isSaved(artwork) ? "heart.fill" : "heart")
                            .font(.system(size: 13)).frame(width: 29, height: 29)
                            .background(reduceTransparency ? AnyShapeStyle(MuseumStyle.canvas) : AnyShapeStyle(.regularMaterial), in: Circle())
                    }.buttonStyle(.plain).padding(8).accessibilityLabel(model.isSaved(artwork) ? "取消收藏" : "收藏")
                }
            }
            Text(artwork.displayTitle).font(.system(size: 17, weight: .regular, design: .serif))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text("\(artwork.displayArtist) · \(artwork.dateDisplay)")
                .font(.system(size: 12)).foregroundStyle(MuseumStyle.muted).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("桌面预览…") { model.selectedArtwork = artwork }.disabled(!artwork.isPublicDomain || model.isSettingWallpaper)
            Button(model.isSaved(artwork) ? "取消收藏" : "收藏") { model.toggleSaved(artwork) }
            Divider()
            Button("复制作品信息") { model.copyInfo(artwork) }
            Link("在博物馆网站打开", destination: artwork.sourceURL)
        }
    }
}

struct ArtworkImageView: View {
    let artwork: Artwork
    let purpose: ImagePurpose
    var fill = false
    var pixelSize = 640
    var fallbackURL: URL?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var visible = false
    @State private var retryToken = 0
    private var decodeSize: Int { purpose == .detail ? 2000 : min(1280, max(64, ((pixelSize + 63) / 64) * 64)) }

    var body: some View {
        ZStack {
            Color.primary.opacity(0.035)
            if let image {
                if fill { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(nsImage: image).resizable().scaledToFit() }
            } else if failed {
                Image(systemName: "photo").font(.system(size: 20, weight: .ultraLight)).foregroundStyle(.tertiary)
            }
        }.clipped().accessibilityHidden(true)
        .overlay(alignment: .bottom) {
            if failed, purpose == .detail {
                Button("重新载入图片") { retryToken += 1 }
                    .buttonStyle(.bordered).padding(12).accessibilityLabel("重新载入\(artwork.displayTitle)的高清图片")
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; image = nil }
        .task(id: "\(artwork.id)-\(artwork.image.originalURL)-\(purpose)-\(decodeSize)-\(visible)-\(retryToken)") {
            guard visible else { return }
            failed = false
            if let fallbackURL { image = NSImage(contentsOf: fallbackURL) }
            do {
                if purpose == .detail,
                   let preview = try? await ImageCache.shared.decodedImage(for: artwork, purpose: .thumbnail, maxPixelSize: 640) {
                    try Task.checkCancellation()
                    image = NSImage(cgImage: preview.image, size: .zero)
                }
                let decoded = try await ImageCache.shared.decodedImage(for: artwork, purpose: purpose, maxPixelSize: decodeSize)
                try Task.checkCancellation()
                guard visible else { return }
                image = NSImage(cgImage: decoded.image, size: .zero)
                if purpose == .detail {
                    PerformanceDiagnostics.mark("detail-view-ready", fields: ["artworkID": artwork.id,
                        "pixelWidth": String(decoded.image.width), "pixelHeight": String(decoded.image.height)])
                }
            } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch { failed = true }
        }
    }
}
