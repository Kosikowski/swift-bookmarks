public import Foundation

/// What an ``EvictionPolicy`` knows about a record when a store is over its limit.
public struct EvictionCandidate: Sendable, Hashable {
    /// Whether the bookmark resolved the last time it was used.
    public var status: RecordStatus
    /// The item's path when it last resolved.
    public var lastKnownPath: String
    /// When the record was first stored.
    public var createdAt: Date
    /// When the item was last used, if the store knows.
    public var lastUsedAt: Date?
    /// Whether the app pinned the record.
    public var isPinned: Bool
    /// Whether the record holds a bookmark, rather than a path only.
    public var hasBookmark: Bool
    /// The record's position in the store's order, `0` first.
    public var position: Int
    /// The store's order.
    public var ordering: RecordOrdering

    /// Creates a candidate.
    public init(
        status: RecordStatus,
        lastKnownPath: String,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
        hasBookmark: Bool = true,
        position: Int,
        ordering: RecordOrdering = .insertion
    ) {
        self.status = status
        self.lastKnownPath = lastKnownPath
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.hasBookmark = hasBookmark
        self.position = position
        self.ordering = ordering
    }

    init<Key, Metadata>(_ record: BookmarkRecord<Key, Metadata>, position: Int, ordering: RecordOrdering) {
        self.init(
            status: record.status,
            lastKnownPath: record.lastKnownPath,
            createdAt: record.createdAt,
            lastUsedAt: record.lastUsedAt,
            isPinned: record.isPinned,
            hasBookmark: record.hasBookmark,
            position: position,
            ordering: ordering
        )
    }

    /// Whether the item was last seen in a Trash.
    public var isInTrash: Bool {
        NormalizedPath(lastKnownPath).isInTrash
    }

    /// Whether the item is gone as far as the store knows: missing, recording nothing, or in a
    /// Trash. Matches ``BookmarkRecord/isGone``.
    public var isGone: Bool {
        switch status.failure {
        case .missing?, .corrupt?: true
        default: isInTrash
        }
    }

    /// When the item was last used, or stored when that isn't known.
    public var lastUse: Date {
        lastUsedAt ?? createdAt
    }

    /// Whether this record comes before `other` in the store's order from least to most
    /// recent: first in insertion order, last in most-recently-used order.
    public func isLessRecentInStoreOrder(than other: EvictionCandidate) -> Bool {
        switch ordering {
        case .insertion: position < other.position
        case .mostRecentlyUsed: position > other.position
        }
    }
}

/// Decides which records a store removes when an addition takes it past
/// ``StorePolicy/limit``.
///
/// A policy protects some records and orders the rest; the store removes records in that
/// order until it's back at its limit, never the record being added. When every other
/// record is protected, the store stays over its limit. The built-in policies protect pinned
/// records whose item isn't gone:
///
/// ```swift
/// // A document history of 500: gone files first, then the least recently used, never a
/// // pinned file that still exists.
/// StorePolicy(limit: 500, eviction: .goneFirst, recordsLastUse: true)
/// ```
///
/// Policies see what the store knows now and don't touch the file system. Statuses come from
/// the last resolution; call ``BookmarkStore/refreshStatuses(includingAvailable:)`` first
/// for current ones. Evicted records are reported by ``BookmarkStore/evictions(bufferingPolicy:)``.
public struct EvictionPolicy: Sendable {
    private let protects: @Sendable (EvictionCandidate) -> Bool
    private let evictsFirst: @Sendable (EvictionCandidate, EvictionCandidate) -> Bool

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - protects: Whether a record is never evicted. Defaults to pinned records whose item
    ///     isn't gone.
    ///   - evictsFirst: Whether the first record goes before the second. It must be a strict
    ///     weak ordering; records it doesn't separate go in the store's order, least recent
    ///     first.
    public init(
        protects: @escaping @Sendable (EvictionCandidate) -> Bool = EvictionPolicy.protectsPinned,
        evictsFirst: @escaping @Sendable (EvictionCandidate, EvictionCandidate) -> Bool
    ) {
        self.protects = protects
        self.evictsFirst = evictsFirst
    }

    /// Protects pinned records whose item isn't gone.
    public static let protectsPinned: @Sendable (EvictionCandidate) -> Bool = { $0.isPinned && !$0.isGone }

    /// The least recent records in the store's order first: the oldest in insertion order,
    /// the least recently used in most-recently-used order. The default.
    public static let storeOrder = EvictionPolicy { $0.isLessRecentInStoreOrder(than: $1) }

    /// The records used longest ago first, by ``BookmarkRecord/lastUsedAt``, or by when they
    /// were stored when that isn't known.
    public static let leastRecentlyUsed = EvictionPolicy { $0.lastUse < $1.lastUse }

    /// Records whose item is gone first, then the ones used longest ago. Gone means missing,
    /// recording nothing or in a Trash, as ``BookmarkRecord/isGone`` says.
    public static let goneFirst = EvictionPolicy { lhs, rhs in
        lhs.isGone != rhs.isGone ? lhs.isGone : lhs.lastUse < rhs.lastUse
    }

    /// Whether the policy never evicts `candidate`.
    public func isProtected(_ candidate: EvictionCandidate) -> Bool {
        protects(candidate)
    }

    /// The positions of `candidates` in the order they would be evicted, leaving out
    /// protected ones.
    public func evictionOrder(of candidates: [EvictionCandidate]) -> [Int] {
        candidates.indices
            .filter { !protects(candidates[$0]) }
            .sorted { lhs, rhs in
                let (a, b) = (candidates[lhs], candidates[rhs])
                if evictsFirst(a, b) { return true }
                if evictsFirst(b, a) { return false }
                return a.isLessRecentInStoreOrder(than: b)
            }
    }
}
