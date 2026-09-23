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

    /// Whether ``load()`` returns each record's status, file identity, last known path and
    /// dates as they were saved. Defaults to `true`.
    ///
    /// Return `false` from an adapter for a format that keeps only keys, bookmark bytes and
    /// metadata. The store then keeps those fields in memory for every record whose bytes and
    /// kind haven't changed since it last saw them, so a write doesn't reset what resolving
    /// learned. What ``load()`` returns for them, such as a path read out of the bookmark, is
    /// used for records the store hasn't seen yet.
    var storesRecordState: Bool { get }

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
    public var storesRecordState: Bool { true }

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

/// Records decoded from the built-in JSON format, plus what this version can't read.
///
/// A record can be unreadable because a newer version of the library or the app wrote a
/// field value this version doesn't know. Such records are kept verbatim and written back
/// unchanged, so running an older build never loses them. Fields a newer version added to a
/// record this version can read are kept the same way.
struct StoredRecords<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable> {
    var records: [BookmarkRecord<Key, Metadata>] = []
    /// Fields of readable records that this version doesn't know, by record key.
    var unknownFields: [Key: [String: JSONValue]] = [:]
    var preserved: [JSONValue] = []
}

struct PersistedEnvelope<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: Codable {
    /// Raise only when the envelope itself changes incompatibly. New record fields and new
    /// enum cases don't need a new version: unknown fields and unreadable records are
    /// preserved.
    static var currentSchemaVersion: Int { 1 }

    let schemaVersion: Int
    let records: [Entry]

    enum Entry: Codable {
        case record(BookmarkRecord<Key, Metadata>, unknownFields: [String: JSONValue])
        case unreadable(JSONValue)

        init(from decoder: any Decoder) throws {
            let record: BookmarkRecord<Key, Metadata>
            do {
                record = try BookmarkRecord(from: decoder)
            } catch {
                self = .unreadable(try JSONValue(from: decoder))
                return
            }
            let fields = (try? [String: JSONValue](from: decoder)) ?? [:]
            self = .record(record, unknownFields: fields.filter { !BookmarkRecord<Key, Metadata>.fieldNames.contains($0.key) })
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .record(let record, let unknownFields):
                try record.encode(to: encoder)
                var container = encoder.container(keyedBy: FieldName.self)
                for (name, value) in unknownFields {
                    try container.encode(value, forKey: FieldName(name))
                }
            case .unreadable(let value):
                try value.encode(to: encoder)
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
            case .record(let record, let unknownFields):
                stored.records.append(record)
                if !unknownFields.isEmpty {
                    stored.unknownFields[record.key] = unknownFields
                }
            case .unreadable(let value):
                stored.preserved.append(value)
            }
        }
        if !stored.preserved.isEmpty {
            // Expected after a newer version wrote the file, and nothing is lost.
            Log.persistence.notice("Kept \(stored.preserved.count, privacy: .public) stored bookmarks this version can't read")
        }
        return stored
    }

    /// Encodes `records`, keeping what `stored` holds that this version can't read.
    ///
    /// Unknown fields go back on the record with the same key. An unreadable record whose key
    /// is now used by one of `records` is dropped, so the file never holds a key twice.
    static func encode(
        _ records: [BookmarkRecord<Key, Metadata>],
        over stored: StoredRecords<Key, Metadata> = StoredRecords(),
        pretty: Bool
    ) throws(PersistenceError) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        do {
            let keys = try Set(records.map { try JSONValue(encoding: $0.key, with: encoder) })
            let preserved = stored.preserved.filter { value in
                guard case .object(let fields) = value, let key = fields["key"] else { return true }
                return !keys.contains(key)
            }
            let envelope = Self(
                schemaVersion: currentSchemaVersion,
                records: records.map { .record($0, unknownFields: stored.unknownFields[$0.key] ?? [:]) }
                    + preserved.map(Entry.unreadable)
            )
            return try encoder.encode(envelope)
        } catch {
            throw PersistenceError(.writeFailed, underlying: error as NSError)
        }
    }
}

private struct FieldName: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct SchemaProbe: Decodable {
    let schemaVersion: Int
}
