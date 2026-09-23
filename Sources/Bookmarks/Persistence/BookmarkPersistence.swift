import Foundation
import os

/// Loads and saves a store's records.
///
/// Implement this to keep an existing storage format: map the stored shape to
/// ``BookmarkRecord`` in ``load()`` and back in ``save(_:)``, keeping keys and bookmark bytes
/// unchanged. ``BookmarkStore`` calls these methods on its own blocking executor, one at a
/// time, and they must not call back into the store.
public protocol BookmarkPersistence<Key, Metadata>: Sendable {
    associatedtype Key: Hashable & Sendable
    associatedtype Metadata: Sendable

    /// Loads all records, in the order they were saved.
    func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]

    /// Replaces all stored records.
    func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError)

    /// Reads the stored records, passes them to `transform`, and saves what it returns, or
    /// nothing when it returns `nil`.
    ///
    /// The store makes every change through this method, applying the change to what is
    /// stored now rather than to what it loaded earlier, so changes another process saved in
    /// between survive. The default implementation calls ``load()`` and then ``save(_:)``.
    /// Override it when other processes write the same storage, so that nothing can write
    /// between the read and the save.
    func update(
        _ transform: ([BookmarkRecord<Key, Metadata>]) -> [BookmarkRecord<Key, Metadata>]?
    ) throws(PersistenceError)
}

extension BookmarkPersistence {
    public func update(
        _ transform: ([BookmarkRecord<Key, Metadata>]) -> [BookmarkRecord<Key, Metadata>]?
    ) throws(PersistenceError) {
        if let records = transform(try load()) {
            try save(records)
        }
    }
}

/// What a persistence backend does with stored data it can't decode.
public enum CorruptionHandling: Sendable, Hashable {
    /// Move the data aside and start empty, so the app keeps working.
    case quarantine
    /// Fail loading with ``PersistenceError/Reason/unreadable``.
    case fail
}

/// Records decoded from the built-in JSON format, plus the ones this version can't read.
///
/// A record can be unreadable because a newer version of the library or the app wrote a
/// field value this version doesn't know. Such records are kept verbatim and written back
/// unchanged, so running an older build never loses them.
struct StoredRecords<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable> {
    var records: [BookmarkRecord<Key, Metadata>] = []
    var preserved: [JSONValue] = []
}

struct PersistedEnvelope<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: Codable {
    /// Raise only when the envelope itself changes incompatibly. New record fields and new
    /// enum cases don't need a new version: unreadable records are preserved.
    static var currentSchemaVersion: Int { 1 }

    let schemaVersion: Int
    let records: [Entry]

    enum Entry: Codable {
        case record(BookmarkRecord<Key, Metadata>)
        case unreadable(JSONValue)

        init(from decoder: any Decoder) throws {
            do {
                self = .record(try BookmarkRecord(from: decoder))
            } catch {
                self = .unreadable(try JSONValue(from: decoder))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .record(let record): try record.encode(to: encoder)
            case .unreadable(let value): try value.encode(to: encoder)
            }
        }
    }

    static func decode(_ data: Data) throws(PersistenceError) -> StoredRecords<Key, Metadata> {
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
        let entries: [Entry]
        do {
            entries = try decoder.decode(Self.self, from: data).records
        } catch {
            throw PersistenceError(.unreadable, underlying: error as NSError)
        }
        var stored = StoredRecords<Key, Metadata>()
        for entry in entries {
            switch entry {
            case .record(let record): stored.records.append(record)
            case .unreadable(let value): stored.preserved.append(value)
            }
        }
        if !stored.preserved.isEmpty {
            Log.persistence.error("Kept \(stored.preserved.count, privacy: .public) stored bookmarks this version can't read")
        }
        return stored
    }

    static func encode(
        _ records: [BookmarkRecord<Key, Metadata>],
        preserving preserved: [JSONValue] = [],
        pretty: Bool
    ) throws(PersistenceError) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let envelope = Self(
            schemaVersion: currentSchemaVersion,
            records: records.map(Entry.record) + preserved.map(Entry.unreadable)
        )
        do {
            return try encoder.encode(envelope)
        } catch {
            throw PersistenceError(.writeFailed, underlying: error as NSError)
        }
    }
}

private struct SchemaProbe: Decodable {
    let schemaVersion: Int
}
