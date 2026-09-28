/// A store's records at one moment, readable synchronously from any thread.
///
/// ``BookmarkStore/snapshot`` holds the records as of the last change the store saved or
/// loaded, so code that can't wait, such as a view's body, reads them without `await`.
/// Subscribe to ``BookmarkStore/updates(bufferingPolicy:)`` to learn when it changes.
public struct StoreSnapshot<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// Every record in the store's order, including unavailable and path-only ones.
    public let records: [BookmarkRecord<Key, Metadata>]
    /// Whether the store had loaded its records. Before that, the snapshot is empty.
    public let isLoaded: Bool
    private let positions: [Key: Int]

    /// Creates a snapshot of `records`, in order.
    public init(records: [BookmarkRecord<Key, Metadata>] = [], isLoaded: Bool = true) {
        self.records = records
        self.isLoaded = isLoaded
        var positions: [Key: Int] = [:]
        for (position, record) in records.enumerated() where positions[record.key] == nil {
            positions[record.key] = position
        }
        self.positions = positions
    }

    /// The record for `key`, or `nil` when there is none.
    public subscript(key: Key) -> BookmarkRecord<Key, Metadata>? {
        positions[key].map { records[$0] }
    }

    /// The keys in the store's order.
    public var keys: [Key] {
        records.map(\.key)
    }

    /// Whether a record exists for `key`.
    public func contains(_ key: Key) -> Bool {
        positions[key] != nil
    }

    /// The number of records.
    public var count: Int {
        records.count
    }

    /// Whether there are no records.
    public var isEmpty: Bool {
        records.isEmpty
    }
}

extension StoreSnapshot: Equatable where Metadata: Equatable {
    public static func == (lhs: StoreSnapshot, rhs: StoreSnapshot) -> Bool {
        lhs.isLoaded == rhs.isLoaded && lhs.records == rhs.records
    }
}
