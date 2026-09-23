/// Decides which resolution failures remove a record from a store.
public struct FailureHandling: Sendable {
    private let dropsRecord: @Sendable (BookmarkFailure) -> Bool

    /// Drops records whose failures match `predicate`.
    public init(dropWhen predicate: @escaping @Sendable (BookmarkFailure) -> Bool) {
        dropsRecord = predicate
    }

    /// Never drops a record; failing records are marked unavailable.
    public static let keep = FailureHandling { _ in false }

    /// Drops records whose item no longer exists; keeps the rest.
    public static let dropMissing = FailureHandling { $0 == .missing }

    /// Whether `failure` removes the record.
    public func drops(_ failure: BookmarkFailure) -> Bool {
        dropsRecord(failure)
    }
}

/// What a store does when a newly added item is already stored under another key.
public enum DuplicateHandling: Sendable, Hashable {
    /// Fail with ``BookmarkStoreError/duplicate(of:)``.
    case reject
    /// Return the existing record unchanged.
    case returnExisting
    /// Store the item again under the new key.
    case allow
}

/// The order in which a store keeps its records.
public enum RecordOrdering: Sendable, Hashable {
    /// Oldest first.
    case insertion
    /// Most recently added or leased first, for recents lists.
    case mostRecentlyUsed
}

/// How a ``BookmarkStore`` behaves.
public struct StorePolicy: Sendable {
    /// Which failures remove records. Defaults to keeping every record.
    public var failureHandling: FailureHandling
    /// What happens when an added item is already stored.
    public var duplicates: DuplicateHandling
    /// The order of ``BookmarkStore/records()``.
    public var ordering: RecordOrdering
    /// The maximum number of records. The last records in order are removed beyond it.
    public var limit: Int?
    /// Checks run on items before they're added or re-granted.
    public var validators: [any GrantValidator]
    /// How records are resolved when leased.
    public var resolution: ResolutionPolicy
    /// Whether a re-grant must pick the same item, by file identity, as the original.
    public var requiresSameItemOnRegrant: Bool

    /// Creates a policy.
    public init(
        failureHandling: FailureHandling = .keep,
        duplicates: DuplicateHandling = .reject,
        ordering: RecordOrdering = .insertion,
        limit: Int? = nil,
        validators: [any GrantValidator] = [],
        resolution: ResolutionPolicy = .default,
        requiresSameItemOnRegrant: Bool = false
    ) {
        precondition(limit.map { $0 > 0 } ?? true, "A store limit must be positive")
        self.failureHandling = failureHandling
        self.duplicates = duplicates
        self.ordering = ordering
        self.limit = limit
        self.validators = validators
        self.resolution = resolution
        self.requiresSameItemOnRegrant = requiresSameItemOnRegrant
    }

    /// Keeps every record, rejects duplicates, keeps insertion order.
    public static let `default` = StorePolicy()

    /// A bounded most-recently-used list that keeps unavailable items.
    public static func recents(limit: Int) -> StorePolicy {
        StorePolicy(duplicates: .returnExisting, ordering: .mostRecentlyUsed, limit: limit)
    }
}

/// A change to a store's records.
public enum StoreChange<Key: Hashable & Sendable>: Sendable, Hashable {
    case added(Key)
    case updated(Key)
    case removed(Key)
}
