import Foundation

enum ArtworkAttribute: String, CaseIterable, Sendable {
    case landscape = "横向", portrait = "纵向", square = "近方形", publicDomain = "Public Domain", highResolution = "高清可用"
}

struct GalleryFilter: Equatable, Sendable {
    var query = ""
    var theme: String?
    var attribute: ArtworkAttribute?
    var movement: String?
    var color: String?
    var artist: String?
    var museum: String?
    var fitsScreen = false
    var withGuide = false
    var screenID: String? // nil: main; "all": every connected display

    var isActive: Bool {
        !query.isEmpty || theme != nil || attribute != nil || movement != nil || color != nil || artist != nil || museum != nil || fitsScreen || withGuide
    }

    func matches(_ artwork: Artwork, screens: [ScreenProfile]) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard words.allSatisfy({ artwork.searchText.localizedStandardContains(String($0)) }) else { return false }
        if let theme, !artwork.themes.contains(theme) { return false }
        if let movement, artwork.movement != movement { return false }
        if let color, !artwork.dominantColors.contains(color) { return false }
        if let artist, artwork.artistOriginal != artist { return false }
        if let museum, artwork.museumName != museum { return false }
        if withGuide, artwork.guideStatus != .published || artwork.guide == nil { return false }
        switch attribute {
        case .landscape: if !artwork.image.hasVerifiedResolution || artwork.aspectRatio <= 1.12 { return false }
        case .portrait: if !artwork.image.hasVerifiedResolution || artwork.aspectRatio >= 0.9 { return false }
        case .square: if !artwork.image.hasVerifiedResolution || !(0.9...1.12).contains(artwork.aspectRatio) { return false }
        case .publicDomain: if !artwork.isPublicDomain { return false }
        case .highResolution: if max(artwork.image.width, artwork.image.height) < 3000 { return false }
        case nil: break
        }
        if fitsScreen {
            let target: WallpaperTarget = screenID == "all" ? .all : screenID.map(WallpaperTarget.display) ?? .main
            guard let targets = try? target.resolve(in: screens, currentID: nil), !targets.isEmpty, targets.allSatisfy({ ScreenFitEngine().evaluate(artwork, screen: $0).qualifies }) else { return false }
        }
        return true
    }
}
