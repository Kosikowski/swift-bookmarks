import Foundation
import os

/// Stores records as JSON under one `UserDefaults` key.
///
/// Suitable for a handful of bookmarks. Undecodable data is moved to `<key>.corrupted` when
/// ``CorruptionHandling/quarantine`` applies.
public struct UserDefaultsPersistence<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: BookmarkPersistence {
    /// The defaults key holding the records.
    public let key: String
    /// The defaults suite, or `nil` for the standard defaults.
    public let suiteName: String?
    /// What happens to undecodable data.
    public let corruption: CorruptionHandling

    /// Creates a persistence for `key` in the given suite.
    public init(key: String, suiteName: String? = nil, corruption: CorruptionHandling = .quarantine) {
        self.key = key
        self.suiteName = suiteName
        self.corruption = corruption
    }

    /// The key that receives undecodable data.
    public var quarantineKey: String { key + ".corrupted" }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let defaults = try defaults()
        guard let data = defaults.data(forKey: key) else {
            if defaults.object(forKey: key) != nil {
                return try handleCorruption(of: nil, in: defaults, error: PersistenceError(.unreadable))
            }
            return []
        }
        do {
            return try PersistedEnvelope<Key, Metadata>.decode(data)
        } catch where error.reason == .unreadable {
            return try handleCorruption(of: data, in: defaults, error: error)
        }
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        let data = try PersistedEnvelope<Key, Metadata>.encode(records, pretty: false)
        try defaults().set(data, forKey: key)
    }

    private func defaults() throws(PersistenceError) -> UserDefaults {
        guard let suiteName else { return .standard }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PersistenceError(.readFailed)
        }
        return defaults
    }

    private func handleCorruption(
        of data: Data?,
        in defaults: UserDefaults,
        error: PersistenceError
    ) throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        guard corruption == .quarantine else { throw error }
        Log.persistence.error("Stored bookmarks under \(key, privacy: .public) are unreadable; moving them aside")
        defaults.set(data ?? defaults.object(forKey: key), forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        return []
    }
}
