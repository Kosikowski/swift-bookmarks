import Foundation

/// Loads and saves a store's records.
///
/// Implement this to keep an existing storage format: map the stored shape to
/// ``BookmarkRecord`` in ``load()`` and back in ``save(_:)``, keeping keys and bookmark bytes
/// unchanged. ``BookmarkStore`` calls both methods on its blocking executor, one at a time,
/// and they must not call back into the store.
public protocol BookmarkPersistence<Key, Metadata>: Sendable {
    associatedtype Key: Hashable & Sendable & Codable
    associatedtype Metadata: Sendable & Codable

    /// Loads all records, in the order they were saved.
    func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]

    /// Replaces all stored records.
    func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError)
}

/// What a persistence backend does with stored data it can't decode.
public enum CorruptionHandling: Sendable, Hashable {
    /// Move the data aside and start empty, so the app keeps working.
    case quarantine
    /// Fail loading with ``PersistenceError/Reason/unreadable``.
    case fail
}

struct PersistedEnvelope<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: Codable {
    static var currentSchemaVersion: Int { 1 }

    let schemaVersion: Int
    let records: [BookmarkRecord<Key, Metadata>]

    init(records: [BookmarkRecord<Key, Metadata>]) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
    }

    static func decode(_ data: Data) throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version: Int
        do {
            version = try decoder.decode(SchemaProbe.self, from: data).schemaVersion
        } catch {
            throw PersistenceError(.unreadable, underlying: error as NSError)
        }
        guard version <= currentSchemaVersion else {
            throw PersistenceError(.unsupportedSchemaVersion(version))
        }
        do {
            return try decoder.decode(Self.self, from: data).records
        } catch {
            throw PersistenceError(.unreadable, underlying: error as NSError)
        }
    }

    static func encode(_ records: [BookmarkRecord<Key, Metadata>], pretty: Bool) throws(PersistenceError) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        do {
            return try encoder.encode(Self(records: records))
        } catch {
            throw PersistenceError(.writeFailed, underlying: error as NSError)
        }
    }
}

private struct SchemaProbe: Decodable {
    let schemaVersion: Int
}
