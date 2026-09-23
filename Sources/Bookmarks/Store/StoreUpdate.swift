/// A change to a store's records.
public enum StoreChange<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// A record was added at the end of the order.
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

extension StoreChange: Equatable where Metadata: Equatable {}
extension StoreChange: Hashable where Metadata: Hashable {}
extension StoreUpdate: Equatable where Metadata: Equatable {}
extension StoreUpdate: Hashable where Metadata: Hashable {}
