import SwiftUI

/// Uses the existing artwork detail and source-backed editorial snapshot.
struct ArtistDetailView: View {
    let artist: Artist
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(artist.displayName).font(.system(size: 30, design: .serif)).textSelection(.enabled)
                    Text(artist.nameOriginal).font(.system(size: 15, design: .serif)).foregroundStyle(.secondary)
                    Text([artist.yearsDisplay, artist.region].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                if let biography = artist.shortBioZh {
                    Text(biography).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: 650, alignment: .leading)
                }
                HStack(spacing: 18) {
                    Button("在艺术史中查看 ↗") {
                        _ = model.focusHistory(.artist(artist.id))
                        dismiss()
                    }.buttonStyle(.plain)
                    Menu("资料来源") {
                        ForEach(artist.sourceRefs, id: \.self) { url in Link(url.host ?? "来源", destination: url) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24)], alignment: .leading, spacing: 28) {
                    ForEach(model.artHistory.artworks(for: artist.id)) { artwork in
                        NavigationLink {
                            ArtworkDetailView(artwork: artwork, model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ArtworkImageView(artwork: artwork, purpose: .thumbnail, pixelSize: 960)
                                    .frame(height: 190)
                                Text(artwork.displayTitle).font(.system(size: 16, design: .serif)).lineLimit(2)
                                Text(artwork.dateDisplay).font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("打开\(artwork.displayTitle)，\(artwork.dateDisplay)")
                            .contextMenu {
                                Button(model.isSaved(artwork) ? "取消收藏" : "收藏") { model.toggleSaved(artwork) }
                            }
                    }
                }
            }.padding(32)
        }.background(MuseumStyle.canvas).navigationTitle(artist.displayName)
            .accessibilityIdentifier("artistDetail")
    }
}
