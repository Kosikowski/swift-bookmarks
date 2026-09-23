import Synchronization

/// Keeps records in memory, for tests, previews and screenshot builds.
public final class InMemoryPersistence<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: BookmarkPersistence {
    private let records: Mutex<[BookmarkRecord<Key, Metadata>]>
    private let saves = Atomic(0)

    /// Creates a persistence holding `records`.
    public init(records: [BookmarkRecord<Key, Metadata>] = []) {
        self.records = Mutex(records)
    }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        records.withLock { $0 }
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        self.records.withLock { $0 = records }
        saves.add(1, ordering: .relaxed)
    }

    /// The records as last saved.
    public var storedRecords: [BookmarkRecord<Key, Metadata>] {
        records.withLock { $0 }
    }

    /// How many times ``save(_:)`` was called.
    public var saveCount: Int {
        saves.load(ordering: .relaxed)
    }
}
