import Foundation

/// Only routes owned by MuseFrame are accepted; payloads remain a single URL path segment.
enum MuseFrameDeepLink: Equatable, Sendable {
    case gallery
    case artwork(String)
    case artist(String)
    case movement(String)

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "museframe",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased() else { return nil }
        switch host {
        case "gallery":
            guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else { return nil }
            self = .gallery
        case "artwork", "artist", "movement":
            let path = components.percentEncodedPath
            guard path.hasPrefix("/"), !path.dropFirst().contains("/"),
                  let id = String(path.dropFirst()).removingPercentEncoding,
                  Self.isValidArtworkID(id) else { return nil }
            switch host {
            case "artist": self = .artist(id)
            case "movement": self = .movement(id)
            default: self = .artwork(id)
            }
        default:
            return nil
        }
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "museframe"
        switch self {
        case .gallery:
            components.host = "gallery"
        case .artwork(let id), .artist(let id), .movement(let id):
            guard Self.isValidArtworkID(id) else { return nil }
            switch self {
            case .artist: components.host = "artist"
            case .movement: components.host = "movement"
            default: components.host = "artwork"
            }
            components.path = "/\(id)"
        }
        return components.url
    }

    private static func isValidArtworkID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 512, id != ".", id != "..",
              !id.contains(where: { "/\\%?#".contains($0) }) else { return false }
        let forbidden = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        return !id.unicodeScalars.contains(where: forbidden.contains)
    }
}
