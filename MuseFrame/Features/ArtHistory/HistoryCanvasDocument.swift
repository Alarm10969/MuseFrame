import SwiftUI

struct HistoryCanvasDocument: View {
    let layout: HistoryCanvasLayout
    let mode: HistoryCanvasMode
    let snapshot: ArtHistorySnapshot
    @Bindable var model: AppModel
    let selection: ArtHistoryNodeID?
    let focus: ArtHistoryFocus?
    let selectedFocus: ArtHistoryFocus?
    let relationshipKind: ArtistRelationship.Kind?
    let hovered: ArtHistoryNodeID?
    let hover: (ArtHistoryNodeID, Bool) -> Void
    let clearHover: () -> Void
    let clear: () -> Void
    let pan: (CGSize?) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var drawnEdges: [ArtHistoryConnection] {
        let visible = Set(layout.nodes.map(\.id))
        let candidates: [ArtHistoryConnection]
        if let focus { candidates = focus.edges }
        else if let relationshipKind {
            candidates = snapshot.connections(relationshipKind: relationshipKind).filter {
                if case .artistRelationship = $0.kind { return true }; return false
            }
        } else if mode == .graph {
            var movements = Set<ArtHistoryNodeID>()
            candidates = snapshot.connections().filter {
                $0.kind == .movementArtist && movements.insert($0.from).inserted
            }
        } else { candidates = [] }
        return candidates.filter { visible.contains($0.from) && visible.contains($0.to) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(MuseumStyle.canvas).contentShape(Rectangle())
                .onTapGesture(perform: clear)
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { pan($0.translation) }
                    .onEnded { _ in pan(nil) })
            lines.allowsHitTesting(false).accessibilityHidden(true)
            ForEach(Array(layout.nodes.enumerated()), id: \.element.id) { index, node in
                HistoryCanvasNode(node: node, mode: mode, snapshot: snapshot, model: model,
                    selected: selection == node.id, highlighted: hovered == node.id)
                    .opacity(selectedFocus.map { $0.nodeIDs.contains(node.id) ? 1 : 0.24 } ?? 1)
                    .position(node.center)
                    .zIndex(hovered == node.id || selection == node.id ? 2 : 1)
                    .onHover { hover(node.id, $0) }
                    .accessibilitySortPriority(Double(layout.nodes.count - index))
            }
        }.frame(width: layout.size.width, height: layout.size.height)
            .onHover { inside in if !inside { clearHover() } }
    }

    private var lines: some View {
        Canvas { context, size in
            if mode == .timeline {
                for mark in layout.years {
                    var path = Path()
                    path.move(to: CGPoint(x: mark.x, y: 42))
                    path.addLine(to: CGPoint(x: mark.x, y: size.height - 25))
                    context.stroke(path, with: .color(.primary.opacity(contrast == .increased ? 0.16 : 0.055)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 6]))
                    context.draw(Text(String(mark.year)).font(.system(size: 12, design: .serif)).foregroundStyle(.secondary), at: CGPoint(x: mark.x, y: 18))
                }
                if let first = layout.years.first, layout.years.count > 1 {
                    let second = layout.years[1]
                    let scale = (second.x - first.x) / CGFloat(second.year - first.year)
                    for movement in snapshot.movements {
                        guard let node = layout.node(.movement(movement.id)), let start = movement.startYear, let end = movement.endYear else { continue }
                        let y = node.center.y + 29
                        let left = CGPoint(x: first.x + CGFloat(start - first.year) * scale, y: y)
                        let right = CGPoint(x: first.x + CGFloat(end - first.year) * scale, y: y)
                        var range = Path(); range.move(to: left); range.addLine(to: right)
                        let opacity: Double = focus == nil || focus?.nodeIDs.contains(node.id) == true ? 0.12 : 0.035
                        context.stroke(range, with: .color(.primary.opacity(opacity)), lineWidth: 2)
                    }
                }
                for span in layout.lifeSpans {
                    let active = focus?.nodeIDs.contains(.artist(span.id)) ?? false
                    let opacity: Double = focus == nil ? 0.13 : active ? 0.3 : 0.04
                    var path = Path(); path.move(to: span.from); path.addLine(to: span.to)
                    context.stroke(path, with: .color(.primary.opacity(opacity)), lineWidth: 1)
                    for point in [span.from, span.to] {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(.primary.opacity(opacity)))
                    }
                }
            }
            let points = Dictionary(layout.nodes.map { ($0.id, $0.center) }, uniquingKeysWith: { first, _ in first })
            for edge in drawnEdges {
                guard let first = points[edge.from], let last = points[edge.to] else { continue }
                var path = Path()
                path.move(to: first)
                path.addLine(to: last)
                let opacity: Double = focus == nil ? (contrast == .increased ? 0.2 : 0.085) : (contrast == .increased ? 0.56 : 0.28)
                context.stroke(path, with: .color(.primary.opacity(opacity)), style: StrokeStyle(lineWidth: focus == nil ? 0.7 : 0.9, dash: dash(edge.kind)))
            }
        }
    }

    private func dash(_ kind: ArtHistoryConnection.Kind) -> [CGFloat] {
        switch kind {
        case .artistRelationship(.influence), .artworkRelationship(.influence): [4, 5]
        case .artistRelationship(.teacherStudent): [7, 3]
        case .artistRelationship(.parallelPaths): [1, 5]
        default: []
        }
    }
}

private struct HistoryCanvasNode: View {
    let node: HistoryLayoutNode
    let mode: HistoryCanvasMode
    let snapshot: ArtHistorySnapshot
    @Bindable var model: AppModel
    let selected: Bool
    let highlighted: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            switch node.id {
            case .movement(let id):
                if let movement = snapshot.movement(id: id) { movementNode(movement) }
            case .artist(let id):
                if let artist = snapshot.artist(id: id) { artistNode(artist) }
            case .artwork(let id):
                if let artwork = snapshot.artwork(id: id) { artworkNode(artwork) }
            }
        }.frame(width: node.size.width, height: node.size.height)
    }

    private func movementNode(_ movement: Movement) -> some View {
        Button { _ = model.focusHistory(.movement(movement.id)) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(HistoryPalette.color(movement.displayColorToken)).frame(width: 5, height: 5)
                    Text(movement.displayName).font(.system(size: mode == .graph ? 17 : 16, weight: selected ? .medium : .regular, design: .serif)).lineLimit(1)
                }
                Text(movement.yearsDisplay).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 11)
            }.frame(maxWidth: .infinity, alignment: .center).contentShape(Rectangle())
        }.buttonStyle(.plain).help(movement.nameOriginal + " · " + movement.yearsDisplay)
            .accessibilityLabel("\(movement.displayName)，\(movement.yearsDisplay)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func artistNode(_ artist: Artist) -> some View {
        let portrait = (artist.portraitArtworkID.flatMap { snapshot.artwork(id: $0) }) ?? snapshot.artworks(for: artist.id).first
        let movement = artist.movementIDs.first.flatMap { snapshot.movement(id: $0) }
        return Button { _ = model.focusHistory(.artist(artist.id)) } label: {
            VStack(spacing: 5) {
                Group {
                    if let portrait {
                        ArtworkImageView(artwork: portrait, purpose: .thumbnail, fill: true, pixelSize: 256)
                    } else {
                        Circle().fill(.primary.opacity(0.045)).overlay {
                            Text(String(artist.displayName.prefix(1))).font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                        }
                    }
                }.frame(width: 42, height: 42).clipShape(Circle())
                    .overlay(Circle().strokeBorder(selected || highlighted ? Color.primary.opacity(0.55) : HistoryPalette.color(movement?.displayColorToken ?? "gray").opacity(0.5), lineWidth: selected ? 1.8 : 0.8))
                    .padding(2)
                Text(HistoryNodeLabel.artist(artist)).font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1).frame(maxWidth: .infinity)
                if mode == .timeline { Text(artist.yearsDisplay).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(artist.displayName + " · " + artist.nameOriginal + " · " + artist.yearsDisplay)
            .accessibilityLabel("\(artist.displayName)，\(artist.yearsDisplay)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu { Button("艺术家资料…") { model.presentedArtist = artist } }
            .accessibilityAction(named: "艺术家资料") { model.presentedArtist = artist }
    }

    private func artworkNode(_ artwork: Artwork) -> some View {
        let maxWidth: CGFloat = node.size.width - 18
        let width = min(maxWidth, 60 * max(0.1, artwork.aspectRatio))
        let height = width / max(0.1, artwork.aspectRatio)
        return Button {
            _ = model.focusHistory(.artwork(artwork.id))
            model.selectedArtwork = artwork
        } label: {
            VStack(spacing: 5) {
                ArtworkImageView(artwork: artwork, purpose: .thumbnail, pixelSize: 512)
                    .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(.primary.opacity(selected || highlighted ? 0.35 : 0), lineWidth: 1))
                Text(artwork.dateDisplay).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: node.size.width, height: node.size.height).contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if highlighted {
                        Text(artwork.displayTitle).font(.system(size: 11, design: .serif)).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(reduceTransparency ? AnyShapeStyle(MuseumStyle.canvas) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 5))
                            .fixedSize().offset(y: 18)
                    }
                }
        }.buttonStyle(.plain).help(artwork.displayTitle + " · " + artwork.displayArtist + " · " + artwork.dateDisplay)
            .accessibilityLabel("打开\(artwork.displayTitle)，\(artwork.displayArtist)，\(artwork.dateDisplay)")
            .contextMenu {
                Button(model.isSaved(artwork) ? "取消收藏" : "收藏") { model.toggleSaved(artwork) }
                Button("复制作品信息") { model.copyInfo(artwork) }
                Link("在博物馆网站打开", destination: artwork.sourceURL)
            }
    }
}

struct HistoryFocusContext: View {
    let target: ArtHistoryNodeID
    let snapshot: ArtHistorySnapshot
    let relationshipKind: ArtistRelationship.Kind?
    let focusArtist: (String) -> Void
    let showArtist: (String) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var relatedArtist: (artist: Artist, relationship: ArtistRelationship, label: String)? {
        guard case .artist(let id) = target else { return nil }
        let candidates = snapshot.artistRelationships.filter {
            ($0.fromArtistID == id || $0.toArtistID == id) && !$0.sourceRefs.isEmpty
                && (relationshipKind == nil || relationshipKind == $0.kind)
        }.sorted { first, last in
            if first.confidence != last.confidence { return first.confidence > last.confidence }
            let firstRank = relationshipRank(first.kind), lastRank = relationshipRank(last.kind)
            return firstRank == lastRank ? first.id < last.id : firstRank < lastRank
        }
        guard let edge = candidates.first else { return nil }
        let outgoing = edge.fromArtistID == id
        guard let artist = snapshot.artist(id: outgoing ? edge.toArtistID : edge.fromArtistID) else { return nil }
        let name = HistoryNodeLabel.artist(artist)
        let label: String
        switch edge.kind {
        case .influence: label = outgoing ? "影响 → \(name)" : "受\(name)影响"
        case .teacherStudent: label = outgoing ? "学生 · \(name)" : "师从 · \(name)"
        case .crossedPaths: label = "相遇 · \(name)"
        case .parallelPaths: label = "并行探索 · \(name)"
        }
        return (artist, edge, label)
    }

    private func relationshipRank(_ kind: ArtistRelationship.Kind) -> Int {
        switch kind { case .teacherStudent: 0; case .influence: 1; case .crossedPaths: 2; case .parallelPaths: 3 }
    }

    private var title: String {
        switch target {
        case .artist(let id): return snapshot.artist(id: id)?.displayName ?? ""
        case .movement(let id): return snapshot.movement(id: id)?.displayName ?? ""
        case .artwork(let id): return snapshot.artwork(id: id)?.displayTitle ?? ""
        }
    }
    private var text: String {
        switch target {
        case .artist(let id): return snapshot.artist(id: id)?.shortBioZh ?? snapshot.artist(id: id)?.yearsDisplay ?? ""
        case .movement(let id): return snapshot.movement(id: id)?.summaryZh ?? snapshot.movement(id: id)?.yearsDisplay ?? ""
        case .artwork(let id):
            if let artwork = snapshot.artwork(id: id) {
                return artwork.hasPublishedGuide ? artwork.guide?.summary30s ?? "" : artwork.displayArtist + " · " + artwork.dateDisplay
            }
            return ""
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                if case .artist(let id) = target {
                    Button { showArtist(id) } label: {
                        HStack(spacing: 7) { Text(title); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    }.buttonStyle(.plain).font(.system(size: 16, design: .serif))
                        .accessibilityLabel("查看\(title)的艺术家资料")
                } else { Text(title).font(.system(size: 16, design: .serif)) }
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
                if let related = relatedArtist {
                    Button { focusArtist(related.artist.id) } label: {
                        Text(related.label).font(.system(size: 11, weight: .medium)).underline()
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(related.relationship.evidenceSummaryZh)
                        .accessibilityLabel("\(related.label)，聚焦\(related.artist.displayName)")
                        .contextMenu {
                            if let source = related.relationship.sourceRefs.first { Link("关系来源", destination: source) }
                        }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20).contentShape(Circle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("取消艺术史聚焦")
        }.padding(15).background(reduceTransparency ? AnyShapeStyle(MuseumStyle.canvas) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
    }
}

private enum HistoryPalette {
    static func color(_ token: String) -> Color {
        switch token.lowercased() {
        case "ochre", "amber", "gold", "yellow": Color(red: 0.59, green: 0.48, blue: 0.3)
        case "rose", "red", "coral": Color(red: 0.62, green: 0.42, blue: 0.42)
        case "sage", "green", "olive": Color(red: 0.42, green: 0.53, blue: 0.43)
        case "blue", "slate", "indigo": Color(red: 0.4, green: 0.49, blue: 0.6)
        case "violet", "purple", "mauve": Color(red: 0.52, green: 0.45, blue: 0.6)
        case "teal": Color(red: 0.38, green: 0.53, blue: 0.52)
        default: Color.secondary
        }
    }
}
