import Synchronization

/// Keeps records in memory, for tests, previews and screenshot builds.
public final class InMemoryPersistence<Key: Hashable & Sendable, Metadata: Sendable>: BookmarkPersistence {
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

    public func update(
        _ transform: ([BookmarkRecord<Key, Metadata>]) -> [BookmarkRecord<Key, Metadata>]?
    ) throws(PersistenceError) {
        let saved = records.withLock { records in
            guard let updated = transform(records) else { return false }
            records = updated
            return true
        }
        if saved {
            saves.add(1, ordering: .relaxed)
        }
    }

    /// The records as last saved.
    public var storedRecords: [BookmarkRecord<Key, Metadata>] {
        records.withLock { $0 }
    }

    /// How many times ``save(_:)`` or ``update(_:)`` saved records.
    public var saveCount: Int {
        saves.load(ordering: .relaxed)
    }
}
