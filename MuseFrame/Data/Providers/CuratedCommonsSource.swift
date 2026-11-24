import Foundation

/// Reviewed, bundled records only. This is not a general Commons crawler or a blanket rights grant.
struct CuratedCommonsSource: ArtworkSourceProtocol {
    let source = ArtworkSource.commons
    static let dresdenID = "commons-dresden-1839"
    static let dresdenImage = "https://upload.wikimedia.org/wikipedia/commons/0/07/Johan_Christian_Dahl_-_View_of_Dresden_by_Moonlight_-_Google_Art_Project.jpg"

    func search(query: String, page: Int, pageSize: Int) async throws -> [Artwork] {
        guard page == 1, pageSize > 0 else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return try records().filter { query.isEmpty || query == "painting" || $0.searchText.contains(query) }
            .prefix(pageSize).map { $0 }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        guard let artwork = try records().first(where: { $0.id == id }) else { throw ArtworkSourceError.invalidID }
        return artwork
    }

    func fetchImageCandidates(for artwork: Artwork) async throws -> [URL] {
        guard licensePolicy(for: artwork) else { throw ArtworkSourceError.restrictedImage }
        return [artwork.image.originalURL]
    }

    func licensePolicy(for artwork: Artwork) -> Bool {
        artwork.source == .commons && artwork.id == Self.dresdenID && artwork.isPublicDomain
            && artwork.image.license == "Public Domain Mark 1.0 (PD-Art)"
            && artwork.image.originalURL.absoluteString == Self.dresdenImage
    }

    private func records() throws -> [Artwork] {
        guard let url = MuseFrameResources.bundle.url(forResource: "seed", withExtension: "json") else {
            throw ArtworkSourceError.missingSeed
        }
        return try JSONDecoder().decode([Artwork].self, from: Data(contentsOf: url)).filter(licensePolicy)
    }
}
