import Foundation
import Observation
import SwiftData

#if SWIFT_PACKAGE
/// Command Line Tools omit Apple's SwiftData macro plug-in. This is the public
/// PersistentModel expansion for the same schema; storage remains SwiftData.
/// The Xcode target below uses the standard @Model declaration.
final class SavedArtwork: PersistentModel, Observable {
    private var backingData: any BackingData<SavedArtwork> = SavedArtwork.createBackingData()
    private let registrar = ObservationRegistrar()

    var persistentBackingData: any BackingData<SavedArtwork> {
        get { backingData }
        set { backingData = newValue }
    }

    static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            Schema.PropertyMetadata(name: "artworkID", keypath: \SavedArtwork.artworkID,
                defaultValue: nil, metadata: Schema.Attribute(.unique)),
            Schema.PropertyMetadata(name: "savedAt", keypath: \SavedArtwork.savedAt,
                defaultValue: nil, metadata: nil),
            Schema.PropertyMetadata(name: "snapshot", keypath: \SavedArtwork.snapshot,
                defaultValue: nil, metadata: nil)
        ]
    }

    var artworkID: String {
        get {
            registrar.access(self, keyPath: \.artworkID)
            return getValue(forKey: \.artworkID)
        }
        set {
            registrar.withMutation(of: self, keyPath: \.artworkID) {
                setValue(forKey: \.artworkID, to: newValue)
            }
        }
    }

    var savedAt: Date {
        get {
            registrar.access(self, keyPath: \.savedAt)
            return getValue(forKey: \.savedAt)
        }
        set {
            registrar.withMutation(of: self, keyPath: \.savedAt) {
                setValue(forKey: \.savedAt, to: newValue)
            }
        }
    }

    var snapshot: Data {
        get {
            registrar.access(self, keyPath: \.snapshot)
            return getValue(forKey: \.snapshot)
        }
        set {
            registrar.withMutation(of: self, keyPath: \.snapshot) {
                setValue(forKey: \.snapshot, to: newValue)
            }
        }
    }

    init(backingData: any BackingData<SavedArtwork>) {
        self.backingData = backingData
    }

    init(artwork: Artwork) throws {
        artworkID = artwork.id
        savedAt = .now
        snapshot = try JSONEncoder().encode(artwork)
    }
}
#else
@Model final class SavedArtwork {
    @Attribute(.unique) var artworkID: String
    var savedAt: Date
    var snapshot: Data

    init(artwork: Artwork) throws {
        artworkID = artwork.id
        savedAt = .now
        snapshot = try JSONEncoder().encode(artwork)
    }
}
#endif
