/// A change to a store's records.
public enum StoreChange<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// A record was added. It sits at the end of the order unless a ``reordered(_:)`` change
    /// that follows it in the same batch says otherwise, as with most-recently-used ordering.
    case added(BookmarkRecord<Key, Metadata>)
    /// A record changed. Its position is unchanged.
    case updated(BookmarkRecord<Key, Metadata>)
    /// A record was removed.
    case removed(Key)
    /// The order changed. Carries every key in the new order.
    case reordered([Key])
}

/// What a subscriber to ``BookmarkStore/updates(bufferingPolicy:)`` receives.
public enum StoreUpdate<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// Every record in order, delivered first.
    case snapshot([BookmarkRecord<Key, Metadata>])
    /// A change made after the snapshot.
    case change(StoreChange<Key, Metadata>)
}

/// A record a store removed on its own, reported by ``BookmarkStore/evictions(bufferingPolicy:)``.
///
/// Apps that keep their own data under a store's keys clear it when a record is evicted.
public struct StoreEviction<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// Why the store removed a record.
    public enum Reason: Sendable, Hashable {
        /// An addition took the store past ``StorePolicy/limit``.
        case limit
        /// The record failed to resolve with a failure ``StorePolicy/failureHandling`` drops.
        case failure(BookmarkFailure)
    }

    /// The record as it was when it was removed.
    public let record: BookmarkRecord<Key, Metadata>
    /// Why it was removed.
    public let reason: Reason

    /// Creates an eviction.
    public init(record: BookmarkRecord<Key, Metadata>, reason: Reason) {
        self.record = record
        self.reason = reason
    }

    /// The removed record's key.
    public var key: Key { record.key }
}

extension StoreChange: Equatable where Metadata: Equatable {}
extension StoreChange: Hashable where Metadata: Hashable {}
extension StoreUpdate: Equatable where Metadata: Equatable {}
extension StoreUpdate: Hashable where Metadata: Hashable {}
extension StoreEviction: Equatable where Metadata: Equatable {}
extension StoreEviction: Hashable where Metadata: Hashable {}
