import SwiftUI
import WidgetKit
import OSLog

struct ArtworkTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ArtworkEntry {
        ArtworkEntry(date: .now, snapshot: CurrentArtworkSnapshot(
            artworkID: "placeholder", title: "作品名称", artist: "艺术家", dateDisplay: "创作年代",
            summary30s: nil, thumbnailURL: nil, updatedAt: .now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (ArtworkEntry) -> Void) {
        completion(WidgetTimelineSnapshot.load().entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ArtworkEntry>) -> Void) {
        // Shared state is authoritative. Reload requests are hints; WidgetKit
        // controls when it calls us again, independently of the helper's hint.
        let snapshot = WidgetTimelineSnapshot.load()
        Logger(subsystem: "io.museframe.app.widget", category: "timeline").info(
            "Timeline artwork=\(snapshot.artwork?.artworkID ?? "none", privacy: .public) reloadAfter=\(snapshot.reloadDate.timeIntervalSince1970, privacy: .public) preview=\(context.isPreview, privacy: .public)"
        )
        completion(Timeline(entries: [snapshot.entry], policy: .after(snapshot.reloadDate)))
    }
}

struct CurrentArtworkWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ArtworkEntry

    var body: some View {
        Group {
            if let artwork = entry.snapshot {
                Group {
                    if family == .systemSmall { smallArtwork(artwork) }
                    else { mediumArtwork(artwork) }
                }
                .widgetURL(artwork.deepLink)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MuseFrame").font(.system(.title3, design: .serif))
                    Text("尚无当前作品").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(MuseFrameDeepLink.gallery.url)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func smallArtwork(_ artwork: CurrentArtworkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                title(artwork, size: 17).lineLimit(2)
                if artwork.isSaved { savedMark }
            }.layoutPriority(2)
            attribution(artwork).font(.system(size: 10)).lineLimit(2)
                .layoutPriority(1)
            if let guide = guide(artwork) {
                Text(guide).font(.system(size: 11)).lineSpacing(2)
                    .foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumArtwork(_ artwork: CurrentArtworkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                title(artwork, size: 18).lineLimit(2)
                if artwork.isSaved { savedMark }
            }.layoutPriority(2)
            attribution(artwork).font(.system(size: 11)).lineLimit(1)
                .layoutPriority(1)
            if let guide = guide(artwork) {
                Text(guide).font(.system(size: 12)).lineSpacing(2)
                    .foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func title(_ artwork: CurrentArtworkSnapshot, size: CGFloat) -> some View {
        Text(artwork.title).font(.system(size: size, weight: .regular, design: .serif))
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attribution(_ artwork: CurrentArtworkSnapshot) -> some View {
        Text([artwork.artist, artwork.dateDisplay].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .foregroundStyle(.secondary)
    }

    private func guide(_ artwork: CurrentArtworkSnapshot) -> String? {
        guard let text = artwork.summary30s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private var savedMark: some View {
        Image(systemName: "heart.fill").font(.system(size: 9))
            .foregroundStyle(.secondary).accessibilityLabel("已收藏")
    }
}

struct CurrentArtworkWidget: Widget {
    let kind = CurrentArtworkStorage.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkTimelineProvider()) { entry in
            CurrentArtworkWidgetView(entry: entry)
        }
        .configurationDisplayName("当前作品")
        .description("当前壁纸的作品信息与中文导览。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MuseFrameWidgetBundle: WidgetBundle {
    var body: some Widget { CurrentArtworkWidget() }
}
