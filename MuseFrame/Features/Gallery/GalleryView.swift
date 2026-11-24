import SwiftUI

struct GalleryView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var showingArtist = false
    @State private var artistSearch = ""
    @State private var scrollPosition = ScrollPosition()

    private var works: [Artwork] { model.visibleArtworks }
    private var themes: [String] { Array(Set(model.artworks.flatMap(\.themes))).sorted() }
    private var movements: [String] { Array(Set(model.artworks.map(\.movement).filter { !$0.isEmpty })).sorted() }
    private var colors: [String] { Array(Set(model.artworks.flatMap(\.dominantColors))).sorted() }
    private var artists: [String] { Array(Set(model.artworks.map(\.artistOriginal))).sorted() }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    results
                    searchField
                    filters
                    if let notice = model.notice {
                        HStack {
                            Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("关闭状态提示")
                        }
                    }
                    if works.isEmpty {
                        ContentUnavailableView(model.tab == .saved && model.savedDates.isEmpty ? "尚无收藏" : "没有匹配的作品",
                            systemImage: model.tab == .saved ? "heart" : "magnifyingglass",
                            description: Text(model.tab == .saved && model.savedDates.isEmpty ? "" : "试试其他搜索词或筛选条件。"))
                            .frame(height: 360)
                    } else {
                        MasonryGallery(artworks: works, width: geometry.size.width - 64, model: model)
                    }
                    if model.tab == .gallery, model.hasMore, !model.filter.isActive {
                        HStack {
                            Spacer()
                            if model.isLoading { ProgressView().controlSize(.small) }
                            else {
                                Button("载入更多作品") { Task { await model.loadMore() } }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.frame(height: 40)
                            .onAppear { if model.page > 0 { Task { await model.loadMore() } } }
                    }
                }
                .padding(.horizontal, MuseumStyle.margin).padding(.top, 26).padding(.bottom, 32)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.contentOffset.y > max(100, scroll.contentSize.height - scroll.containerSize.height * 3)
            } action: { _, nearEnd in
                if nearEnd, model.tab == .gallery { Task { await model.loadMore() } }
            }
            .onChange(of: model.tab) { _, _ in scrollPosition.scrollTo(edge: .top) }
        }
        .onAppear { PerformanceDiagnostics.mark("gallery-on-appear", once: true) }
        .task(id: model.tab.rawValue + ":" + model.searchInput) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let query = model.searchInput
                model.filter.query = query
                await model.searchMuseum(query)
            } catch {}
        }
        .background {
            Button("搜索") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    private var results: some View {
        HStack(spacing: 12) {
            Text(model.filter.isActive ? "Filtered" : model.tab == .saved ? "Saved" : "Gallery")
                .font(.system(size: 16, weight: .semibold))
            Text(works.count.formatted()).font(.system(size: 17)).foregroundStyle(MuseumStyle.muted)
                .accessibilityLabel("\(works.count) 幅作品").accessibilityIdentifier("resultCount")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if model.filter.fitsScreen { removable("Fits your screen") { model.filter.fitsScreen = false } }
                    if model.filter.withGuide { removable("With guide") { model.filter.withGuide = false } }
                    if let value = model.filter.theme { removable(value) { model.filter.theme = nil } }
                    if let value = model.filter.attribute { removable(value.rawValue) { model.filter.attribute = nil } }
                    if let value = model.filter.movement { removable(value) { model.filter.movement = nil } }
                    if let value = model.filter.color { removable(value) { model.filter.color = nil } }
                    if let value = model.filter.artist { removable(value) { model.filter.artist = nil } }
                    if let value = model.filter.museum { removable(value) { model.filter.museum = nil } }
                }
            }
            if model.tab == .saved {
                Picker("排序", selection: $model.savedSort) { ForEach(SavedSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 128)
            }
        }.frame(height: 28)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("搜索作品或艺术家", text: $model.searchInput).textFieldStyle(.plain)
                .focused($searchFocused).accessibilityIdentifier("artworkSearch")
            if !model.searchInput.isEmpty {
                Button { model.searchInput = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }.font(.system(size: 14)).padding(.horizontal, 14).frame(width: 420, height: 35)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                filterMenu("Theme", values: themes, selection: $model.filter.theme)
                Menu {
                    Button("全部属性") { model.filter.attribute = nil; model.filter.museum = nil }
                    ForEach(ArtworkAttribute.allCases, id: \.self) { value in
                        Button { model.filter.attribute = model.filter.attribute == value ? nil : value } label: {
                            if model.filter.attribute == value { Label(value.rawValue, systemImage: "checkmark") } else { Text(value.rawValue) }
                        }
                    }
                    Divider()
                    ForEach(Array(Set(model.artworks.map(\.museumName))).sorted(), id: \.self) { museum in
                        Button(museum) { model.filter.museum = museum }
                    }
                } label: { menuLabel("Attributes", active: model.filter.attribute != nil || model.filter.museum != nil) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                filterMenu("Movement", values: movements, selection: $model.filter.movement)
                filterMenu("Color", values: colors, selection: $model.filter.color)
                Button { showingArtist.toggle() } label: { menuLabel("Artist", active: model.filter.artist != nil) }
                    .buttonStyle(.plain).popover(isPresented: $showingArtist, arrowEdge: .bottom) {
                        VStack(spacing: 12) {
                            TextField("搜索艺术家", text: $artistSearch).textFieldStyle(.roundedBorder)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    artistOption("全部艺术家", value: nil)
                                    ForEach(artists.filter { artistSearch.isEmpty || artistLabel($0).localizedStandardContains(artistSearch) || $0.localizedStandardContains(artistSearch) }, id: \.self) {
                                        artistOption(artistLabel($0), value: $0)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(16).frame(width: 290, height: 340)
                    }
                Button { model.filter.fitsScreen.toggle() } label: {
                    Label("Fits your screen", systemImage: "display").modifier(CapsuleControl(active: model.filter.fitsScreen))
                }.buttonStyle(.plain).accessibilityIdentifier("fitsScreen")
                .contextMenu {
                    Button("主显示器") { model.filter.screenID = nil; model.filter.fitsScreen = true }
                    ForEach(model.screens) { screen in
                        Button("\(screen.name) · \(screen.pixelWidth) × \(screen.pixelHeight)") { model.filter.screenID = screen.id; model.filter.fitsScreen = true }
                    }
                    if model.screens.count > 1 {
                        Button("适合所有显示器") { model.filter.screenID = "all"; model.filter.fitsScreen = true }
                    }
                }
                Button { model.filter.withGuide.toggle() } label: {
                    Label("With guide", systemImage: "text.bubble").modifier(CapsuleControl(active: model.filter.withGuide))
                }.buttonStyle(.plain).accessibilityIdentifier("withGuide")
            }.padding(.bottom, 2)
        }
    }

    private func filterMenu(_ title: String, values: [String], selection: Binding<String?>) -> some View {
        Menu {
            Button("全部") { selection.wrappedValue = nil }
            ForEach(values, id: \.self) { value in
                Button { selection.wrappedValue = selection.wrappedValue == value ? nil : value } label: {
                    if selection.wrappedValue == value { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
        } label: { menuLabel(title, active: selection.wrappedValue != nil) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func menuLabel(_ title: String, active: Bool) -> some View {
        HStack(spacing: 7) { Text(title); Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
            .modifier(CapsuleControl(active: active))
    }
    private func removable(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(title); Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.primary.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("移除 \(title) 筛选")
    }
    private func artistLabel(_ original: String) -> String {
        guard let work = model.artworks.first(where: { $0.artistOriginal == original }), let zh = work.artistZh else { return original }
        return "\(zh) · \(original)"
    }
    private func artistOption(_ title: String, value: String?) -> some View {
        Button { model.filter.artist = value; showingArtist = false } label: {
            HStack { Text(title).font(.system(size: 12)); Spacer(); if model.filter.artist == value { Image(systemName: "checkmark") } }
                .padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
