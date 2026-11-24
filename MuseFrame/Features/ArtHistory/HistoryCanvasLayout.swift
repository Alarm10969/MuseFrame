import Foundation

enum HistoryCanvasMode: String, CaseIterable, Identifiable, Sendable {
    case timeline = "Timeline", graph = "Graph"
    var id: String { rawValue }
}

struct HistoryLayoutNode: Identifiable, Equatable, Sendable {
    let id: ArtHistoryNodeID
    let center: CGPoint
    let size: CGSize
    var frame: CGRect { CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height) }
}

struct HistoryLifeSpan: Identifiable, Equatable, Sendable {
    let id: String
    let from: CGPoint
    let to: CGPoint
}

struct HistoryYearMark: Identifiable, Equatable, Sendable {
    var id: Int { year }
    let year: Int
    let x: CGFloat
}

/// Positions are computed from immutable content, never from a random force simulation.
struct HistoryCanvasLayout: Equatable, Sendable {
    let nodes: [HistoryLayoutNode]
    let size: CGSize
    let lifeSpans: [HistoryLifeSpan]
    let years: [HistoryYearMark]

    func node(_ id: ArtHistoryNodeID) -> HistoryLayoutNode? { nodes.first { $0.id == id } }

    static func make(snapshot: ArtHistorySnapshot, mode: HistoryCanvasMode, viewport: CGSize,
                     movementID: String? = nil, artistID: String? = nil, focus: ArtHistoryNodeID? = nil) -> HistoryCanvasLayout {
        let selection = HistoryCanvasSelection(snapshot: snapshot, movementID: movementID, artistID: artistID, focus: focus)
        if mode == .timeline { return timeline(selection, snapshot: snapshot, viewport: viewport) }
        return graph(selection, snapshot: snapshot, viewport: viewport)
    }

    private static func graph(_ selection: HistoryCanvasSelection, snapshot: ArtHistorySnapshot, viewport: CGSize) -> HistoryCanvasLayout {
        let width = max(1060, viewport.width)
        let columns = selection.movements.count == 1 ? 1 : (width >= 1600 ? 5 : 4)
        let columnWidth = (width - 48) / CGFloat(columns)
        var nodes: [HistoryLayoutNode] = []
        var placed = Set<ArtHistoryNodeID>()
        var rowTop: CGFloat = 55
        var rowHeight: CGFloat = 265
        for (index, movement) in selection.movements.enumerated() {
            let column = index % columns
            if column == 0, index > 0 { rowTop += rowHeight; rowHeight = 265 }
            let offset: CGFloat = [0, 12, -6, 8, -8][column]
            let center = CGPoint(x: 24 + columnWidth * (CGFloat(column) + 0.5) + offset, y: rowTop + (column.isMultiple(of: 2) ? 0 : 20))
            let movementNode = HistoryLayoutNode(id: .movement(movement.id), center: center, size: CGSize(width: min(220, columnWidth - 10), height: 48))
            nodes.append(movementNode); placed.insert(movementNode.id)
            let artists = selection.artists(in: movement.id).filter { !placed.contains(.artist($0.id)) }
            let works = selection.artworks(in: movement.id, snapshot: snapshot).filter { !placed.contains(.artwork($0.id)) }
            if columns == 1 {
                let artistSpacing = min(180, (width - 120) / CGFloat(max(1, artists.count)))
                let start = width / 2 - CGFloat(max(0, artists.count - 1)) * artistSpacing / 2
                for (offset, artist) in artists.enumerated() {
                    let point = CGPoint(x: start + CGFloat(offset) * artistSpacing, y: center.y + 125 + CGFloat(offset % 2) * 18)
                    nodes.append(HistoryLayoutNode(id: .artist(artist.id), center: point, size: CGSize(width: 138, height: 82)))
                    placed.insert(.artist(artist.id))
                }
                let workColumns = min(6, max(1, works.count))
                let spacing = min(160, (width - 120) / CGFloat(workColumns))
                for (offset, artwork) in works.enumerated() {
                    let point = CGPoint(x: width / 2 + (CGFloat(offset % workColumns) - CGFloat(workColumns - 1) / 2) * spacing,
                        y: center.y + 280 + CGFloat(offset / workColumns) * 120)
                    nodes.append(HistoryLayoutNode(id: .artwork(artwork.id), center: point, size: CGSize(width: 112, height: 96)))
                    placed.insert(.artwork(artwork.id))
                }
                rowHeight = max(rowHeight, 370 + CGFloat(max(0, works.count - 1) / workColumns) * 120)
            } else {
                for (offset, artist) in artists.enumerated() {
                    let side: CGFloat = offset.isMultiple(of: 2) ? -65 : 65
                    let movementYear = Double((movement.startYear ?? 1800) + (movement.endYear ?? movement.startYear ?? 1800)) / 2
                    let chronologicalShift = CGFloat(min(6, max(-6, (artist.activityMidYear - movementYear) / 5)))
                    let point = CGPoint(x: center.x + side + chronologicalShift, y: center.y + 78 + CGFloat(offset / 2) * 90 + CGFloat(offset % 2) * 18)
                    nodes.append(HistoryLayoutNode(id: .artist(artist.id), center: point, size: CGSize(width: 112, height: 78)))
                    placed.insert(.artist(artist.id))
                }
                let workTop = max(178, 95 + CGFloat((artists.count + 1) / 2) * 78)
                for (offset, artwork) in works.enumerated() {
                    let side: CGFloat = works.count == 1 ? 0 : (offset.isMultiple(of: 2) ? -55 : 55)
                    let point = CGPoint(x: center.x + side, y: center.y + workTop + CGFloat(offset / 2) * 98 + CGFloat(offset % 2) * 10)
                    nodes.append(HistoryLayoutNode(id: .artwork(artwork.id), center: point, size: CGSize(width: 96, height: 84)))
                    placed.insert(.artwork(artwork.id))
                }
                rowHeight = max(rowHeight, workTop + CGFloat(max(0, works.count - 1) / 2) * 98 + 75)
            }
        }
        return HistoryCanvasLayout(nodes: nodes, size: CGSize(width: width, height: max(viewport.height, rowTop + rowHeight + 25)), lifeSpans: [], years: [])
    }

    private static func timeline(_ selection: HistoryCanvasSelection, snapshot: ArtHistorySnapshot, viewport: CGSize) -> HistoryCanvasLayout {
        let values = selection.movements.flatMap { [$0.startYear, $0.endYear] }.compactMap { $0 }
            + selection.artists.flatMap { [$0.birthYear, $0.deathYear] }.compactMap { $0 }
            + selection.artworks.compactMap(\.yearStart)
        let minYear = Int(floor(Double(values.min() ?? 1500) / 50)) * 50
        let maxYear = Int(ceil(Double(values.max() ?? 1950) / 50)) * 50 + 25
        let yearScale: CGFloat = 3.1
        func x(_ year: Int) -> CGFloat { 225 + CGFloat(year - minYear) * yearScale }
        var nodes: [HistoryLayoutNode] = []
        var spans: [HistoryLifeSpan] = []
        var placed = Set<ArtHistoryNodeID>()
        var top: CGFloat = 80
        for movement in selection.movements {
            let middleYear: Int
            if let start = movement.startYear, let end = movement.endYear { middleYear = start + (end - start) / 2 }
            else { middleYear = movement.startYear ?? movement.endYear ?? minYear }
            nodes.append(HistoryLayoutNode(id: .movement(movement.id), center: CGPoint(x: x(middleYear), y: top + 10), size: CGSize(width: 190, height: 48)))
            let artists = selection.artists(in: movement.id).filter { !placed.contains(.artist($0.id)) }
            var artistRowEnds: [CGFloat] = []
            for artist in artists {
                let midYear: Int
                if artist.birthYear != nil || artist.deathYear != nil { midYear = Int(artist.activityMidYear.rounded()) }
                else { midYear = snapshot.artworks(for: artist.id).compactMap(\.yearStart).first ?? movement.startYear ?? minYear }
                let centerX = x(midYear)
                let start = x(artist.birthYear ?? midYear), end = x(artist.deathYear ?? midYear)
                let labelStart = min(start, centerX - 70)
                let row = artistRowEnds.firstIndex { $0 + 20 < labelStart } ?? artistRowEnds.count
                if row == artistRowEnds.count { artistRowEnds.append(max(end, centerX + 70)) }
                else { artistRowEnds[row] = max(end, centerX + 70) }
                let y = top + CGFloat(row) * 98 + 100
                nodes.append(HistoryLayoutNode(id: .artist(artist.id), center: CGPoint(x: centerX, y: y), size: CGSize(width: 138, height: 82)))
                if artist.birthYear != nil, artist.deathYear != nil { spans.append(HistoryLifeSpan(id: artist.id, from: CGPoint(x: start, y: y - 10), to: CGPoint(x: end, y: y - 10))) }
                placed.insert(.artist(artist.id))
            }
            let workTop = top + CGFloat(max(1, artistRowEnds.count)) * 98 + 95
            let works = selection.artworks(in: movement.id, snapshot: snapshot).filter { !placed.contains(.artwork($0.id)) }
            var workRowEnds: [CGFloat] = []
            for artwork in works {
                guard let year = artwork.yearStart else { continue }
                let centerX = x(year)
                let row = workRowEnds.firstIndex { $0 + 22 < centerX - 58 } ?? workRowEnds.count
                if row == workRowEnds.count { workRowEnds.append(centerX + 58) } else { workRowEnds[row] = centerX + 58 }
                nodes.append(HistoryLayoutNode(id: .artwork(artwork.id), center: CGPoint(x: centerX, y: workTop + CGFloat(row) * 105), size: CGSize(width: 112, height: 96)))
                placed.insert(.artwork(artwork.id))
            }
            top = workTop + CGFloat(max(1, workRowEnds.count)) * 105 + 38
        }
        let marks = stride(from: minYear, through: maxYear, by: 50).map { HistoryYearMark(year: $0, x: x($0)) }
        return HistoryCanvasLayout(nodes: nodes, size: CGSize(width: max(viewport.width, x(maxYear) + 90), height: max(viewport.height, top)), lifeSpans: spans, years: marks)
    }
}

private struct HistoryCanvasSelection {
    let movements: [Movement]
    let artists: [Artist]
    let artworks: [Artwork]

    init(snapshot: ArtHistorySnapshot, movementID: String?, artistID: String?, focus: ArtHistoryNodeID?) {
        let focusSet = focus.map { snapshot.focus(on: $0).nodeIDs } ?? []
        var movementList = snapshot.movements.filter { movementID == nil || $0.id == movementID }
        if let artistID, let artist = snapshot.artist(id: artistID) { movementList = movementList.filter { artist.movementIDs.contains($0.id) } }
        var chosenArtists = Set<String>(), chosenWorks = Set<String>()
        for movement in movementList {
            let candidates = snapshot.artists.filter { $0.movementIDs.contains(movement.id) && (artistID == nil || $0.id == artistID) }
                .sorted { ($0.importanceRank == $1.importanceRank) ? ($0.activityMidYear, $0.id) < ($1.activityMidYear, $1.id) : $0.importanceRank > $1.importanceRank }
            for artist in candidates.prefix(movementID == nil ? 2 : 6) { chosenArtists.insert(artist.id) }
            let matchingWorks = snapshot.artworks.filter { work in
                snapshot.movements(for: work.id).contains { $0.id == movement.id }
                    && (artistID == nil || snapshot.artist(for: work.id)?.id == artistID)
            }.sorted { ($0.yearStart ?? 0, $0.id) < ($1.yearStart ?? 0, $1.id) }
            // One work from each visible author keeps default clusters sparse and balanced.
            var representedAuthors = Set<String>()
            for work in matchingWorks {
                guard let author = snapshot.artist(for: work.id), chosenArtists.contains(author.id), representedAuthors.insert(author.id).inserted else { continue }
                chosenWorks.insert(work.id)
                if representedAuthors.count >= (movementID == nil ? 2 : 6) { break }
            }
            if movementID != nil || artistID != nil { chosenWorks.formUnion(matchingWorks.prefix(8).map(\.id)) }
        }
        // Focusing a movement preserves the curated overview; its full neighbor set can be
        // much larger than the canvas should display. Search can still reveal any core node.
        let expandNeighbors: Bool
        if case .movement = focus { expandNeighbors = false } else { expandNeighbors = true }
        for target in focusSet where expandNeighbors {
            switch target {
            case .artist(let id):
                if let author = snapshot.artist(id: id), author.movementIDs.contains(where: { id in movementList.contains { $0.id == id } }), artistID == nil || artistID == id { chosenArtists.insert(id) }
            case .artwork(let id):
                if case .artist = focus { continue } // Artist works are bounded below.
                if let work = snapshot.artwork(id: id), snapshot.movements(for: work.id).contains(where: { movement in movementList.contains { $0.id == movement.id } }) {
                    chosenWorks.insert(id)
                    if let author = snapshot.artist(for: id) { chosenArtists.insert(author.id) }
                }
            case .movement: break
            }
        }
        if case .artist(let id) = focus { chosenWorks.formUnion(snapshot.artworks(for: id).prefix(6).map(\.id)) }
        self.movements = movementList
        self.artists = snapshot.artists.filter { chosenArtists.contains($0.id) }.sorted { ($0.activityMidYear, $0.id) < ($1.activityMidYear, $1.id) }
        self.artworks = snapshot.artworks.filter { chosenWorks.contains($0.id) }.sorted { ($0.yearStart ?? 0, $0.id) < ($1.yearStart ?? 0, $1.id) }
    }
    func artists(in movementID: String) -> [Artist] { artists.filter { $0.movementIDs.contains(movementID) } }
    func artworks(in movementID: String, snapshot: ArtHistorySnapshot) -> [Artwork] {
        artworks.filter { work in snapshot.movements(for: work.id).contains { $0.id == movementID } }
    }
}
