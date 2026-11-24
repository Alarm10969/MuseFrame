import SwiftUI

struct ArtHistoryView: View {
    @Bindable var model: AppModel
    @State private var mode: HistoryCanvasMode = .graph
    private var magnification: Double {
        get { model.historyMagnification }
        nonmutating set { model.historyMagnification = newValue }
    }
    @State private var movementID: String?
    @State private var artistID: String?
    @State private var relationshipKind: ArtistRelationship.Kind?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered: ArtHistoryNodeID?
    @State private var focusRequest: HistoryViewportRequest?
    @State private var panRequest: HistoryPanRequest?
    @State private var layout = HistoryCanvasLayout(nodes: [], size: CGSize(width: 1100, height: 700), lifeSpans: [], years: [])

    private var configuration: HistoryLayoutConfiguration {
        HistoryLayoutConfiguration(mode: mode, movementID: movementID, artistID: artistID,
            focus: model.historyFocus, contentVersion: model.artHistory.contentVersion, artworkIDs: model.artHistory.coreArtworkIDs)
    }
    private var activeTarget: ArtHistoryNodeID? { hovered ?? model.historyFocus }
    private var focus: ArtHistoryFocus? { activeTarget.map { model.artHistory.focus(on: $0, relationshipKind: relationshipKind) } }
    private var selectedFocus: ArtHistoryFocus? { model.historyFocus.map { model.artHistory.focus(on: $0, relationshipKind: relationshipKind) } }
    private var results: [ArtHistorySearchResult] { model.artHistory.search(query: query, limit: 7) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                controls.padding(.horizontal, 32).padding(.top, 15).padding(.bottom, 18)
                NativeHistoryScrollView(magnification: $model.historyMagnification, documentSize: layout.size, focus: focusRequest, pan: panRequest) {
                    HistoryCanvasDocument(layout: layout, mode: mode, snapshot: model.artHistory, model: model,
                        selection: model.historyFocus, focus: focus, selectedFocus: selectedFocus,
                        relationshipKind: relationshipKind, hovered: hovered, hover: hover,
                        clearHover: { hovered = nil }, clear: clearSelection, pan: pan)
                }
                .onHover { inside in if !inside { hovered = nil } }
                .accessibilityIdentifier("artHistoryCanvas")
            }
            .overlay(alignment: .topTrailing) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResults.frame(width: 310).padding(.top, 56).padding(.trailing, 178)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let selected = model.historyFocus {
                    HistoryFocusContext(target: selected, snapshot: model.artHistory,
                        relationshipKind: relationshipKind, focusArtist: { choose(.artist($0)) },
                        showArtist: { model.presentedArtist = model.artHistory.artist(id: $0) }, close: clearSelection)
                        .frame(maxWidth: min(540, geometry.size.width - 64), alignment: .leading)
                        .padding(.leading, 32).padding(.bottom, 20)
                }
            }
            .onAppear { hovered = nil; rebuild(viewport: geometry.size, center: true) }
            .onChange(of: geometry.size) { _, size in
                hovered = nil
                rebuild(viewport: size, center: false)
            }
            .onChange(of: configuration) { _, _ in
                hovered = nil
                normalizeFiltersForFocus()
                rebuild(viewport: geometry.size, center: true)
            }
            .onChange(of: relationshipKind) { _, _ in hovered = nil }
            .onExitCommand { if !query.isEmpty { query = "" } else { clearSelection() } }
        }
        .background {
            Button("搜索艺术史") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .sheet(item: $model.presentedArtist) { artist in
            NavigationStack {
                ArtistDetailView(artist: artist, model: model)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { model.presentedArtist = nil }.keyboardShortcut(.cancelAction)
                        }
                    }
            }.frame(width: 1080, height: 720)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(HistoryCanvasMode.allCases) { item in
                    Button { mode = item } label: {
                        Text(item.rawValue).font(.system(size: 12, weight: mode == item ? .semibold : .medium))
                            .padding(.horizontal, 15).frame(height: 31)
                            .background(mode == item ? Color.primary.opacity(0.085) : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(mode == item ? .isSelected : [])
                }
            }.padding(3).background(.primary.opacity(0.035), in: Capsule())
            movementMenu
            artistMenu
            relationshipMenu
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("搜索艺术史", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit { if let result = results.first { choose(result.target); query = "" } }
                    .accessibilityLabel("搜索艺术家、流派或作品").accessibilityIdentifier("historySearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除艺术史搜索")
                }
            }.padding(.horizontal, 11).frame(width: 170, height: 32)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
            HStack(spacing: 12) {
                Button { magnification = max(0.55, magnification - 0.15) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("缩小艺术史")
                Button { magnification = 1 } label: {
                    Text(magnification, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40)
                }.accessibilityLabel("重置艺术史缩放到100%")
                    .accessibilityValue(magnification.formatted(.percent.precision(.fractionLength(0))))
                Button { magnification = min(2.5, magnification + 0.15) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("放大艺术史")
            }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 13).frame(height: 33)
                .background(.primary.opacity(0.035), in: Capsule())
        }
    }

    private var movementMenu: some View {
        Menu {
            Button("全部流派") { movementID = nil; clearSelection() }
            Divider()
            ForEach(model.artHistory.movements) { movement in
                Button { movementID = movement.id; artistID = nil; choose(.movement(movement.id), keepFilters: true) } label: {
                    Text(movement.displayName)
                    if movementID == movement.id { Image(systemName: "checkmark") }
                }
            }
        } label: { HistoryMenuLabel(title: movementID.flatMap { model.artHistory.movement(id: $0)?.displayName } ?? "Movement", active: movementID != nil) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Movement 筛选")
    }
    private var artistMenu: some View {
        Menu {
            Button("全部艺术家") { artistID = nil; clearSelection() }
            Divider()
            ForEach(model.artHistory.artists) { artist in
                Button { artistID = artist.id; movementID = nil; choose(.artist(artist.id), keepFilters: true) } label: {
                    Text(artist.displayName)
                    if artistID == artist.id { Image(systemName: "checkmark") }
                }
            }
        } label: { HistoryMenuLabel(title: artistID.flatMap { model.artHistory.artist(id: $0).map(HistoryNodeLabel.artist) } ?? "Artist", active: artistID != nil) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Artist 筛选")
    }
    private var relationshipMenu: some View {
        Menu {
            Button("全部关系") { relationshipKind = nil }
            Divider()
            ForEach(ArtistRelationship.Kind.allCases, id: \.self) { kind in
                Button { relationshipKind = kind } label: {
                    Text(kind.displayName)
                    if relationshipKind == kind { Image(systemName: "checkmark") }
                }
            }
        } label: { HistoryMenuLabel(title: relationshipKind?.displayName ?? "Relationship", active: relationshipKind != nil) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Relationship 筛选")
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("没有匹配结果").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(results) { result in
                    Button { choose(result.target); query = "" } label: {
                        HStack(spacing: 10) {
                            Image(systemName: searchSymbol(result.target)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(.system(size: 13)).lineLimit(1)
                                Text(result.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("定位\(result.title)")
                }
            }
        }.padding(.vertical, 4).background(reduceTransparency ? AnyShapeStyle(MuseumStyle.canvas) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }

    private func rebuild(viewport: CGSize, center: Bool) {
        let available = CGSize(width: max(1, viewport.width), height: max(1, viewport.height - 68))
        layout = HistoryCanvasLayout.make(snapshot: model.artHistory, mode: mode, viewport: available,
            movementID: movementID, artistID: artistID, focus: model.historyFocus)
        if center, let target = model.historyFocus, let point = layout.node(target)?.center {
            focusRequest = HistoryViewportRequest(point: point)
        }
    }
    private func normalizeFiltersForFocus() {
        guard let target = model.historyFocus else { return }
        if let artistID {
            if case .artist(let id) = target, id == artistID {} else { self.artistID = nil }
        }
        if let movementID {
            let compatible: Bool
            switch target {
            case .movement(let id): compatible = id == movementID
            case .artist(let id): compatible = model.artHistory.artist(id: id)?.movementIDs.contains(movementID) == true
            case .artwork(let id): compatible = model.artHistory.movements(for: id).contains { $0.id == movementID }
            }
            if !compatible { self.movementID = nil }
        }
    }
    private func choose(_ target: ArtHistoryNodeID, keepFilters: Bool = false) {
        hovered = nil
        if !keepFilters { movementID = nil; artistID = nil }
        _ = model.focusHistory(target)
        if let point = layout.node(target)?.center { focusRequest = HistoryViewportRequest(point: point) }
    }
    private func clearSelection() { model.historyFocus = nil; hovered = nil; query = "" }
    private func hover(_ target: ArtHistoryNodeID, _ inside: Bool) {
        if inside { hovered = target } else if hovered == target { hovered = nil }
    }
    private func pan(_ translation: CGSize?) {
        if let translation { panRequest = HistoryPanRequest(token: panRequest?.token ?? UUID(), translation: translation) }
        else { panRequest = nil }
    }
    private func searchSymbol(_ target: ArtHistoryNodeID) -> String {
        switch target { case .artist: "person.crop.circle"; case .movement: "circle.grid.2x2"; case .artwork: "photo" }
    }
}

private struct HistoryLayoutConfiguration: Equatable {
    let mode: HistoryCanvasMode
    let movementID: String?
    let artistID: String?
    let focus: ArtHistoryNodeID?
    let contentVersion: String
    let artworkIDs: Set<String>
}

private struct HistoryMenuLabel: View {
    let title: String
    let active: Bool
    var body: some View {
        HStack(spacing: 7) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
        }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
            .background(active ? Color.primary.opacity(0.06) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(active ? 0.24 : 0.12)))
    }
}

enum HistoryNodeLabel {
    static func artist(_ artist: Artist) -> String {
        let name = artist.displayName
        if name.count > 8, name.contains("·"), let last = name.split(separator: "·").last { return String(last) }
        return name
    }
}
