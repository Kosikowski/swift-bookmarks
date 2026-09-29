import Foundation

struct RecordTable<Key: Hashable & Sendable, Metadata: Sendable & Equatable>: Sendable {
    typealias Record = BookmarkRecord<Key, Metadata>

    struct Snapshot: Sendable {
        let record: Record
        let generation: UInt64

        var key: Key { record.key }
    }

    struct Resolution: Sendable {
        let originalData: BookmarkData
        let refreshedData: BookmarkData?
        let path: String
        let identity: FileIdentity?
        let date: Date
        /// The kind of a bookmark just made for a path-only record, which the record takes on.
        var madeKind: BookmarkKind?
    }

    /// What a transaction changed, for subscribers and the access registry.
    struct Changes: Sendable {
        var changes: [StoreChange<Key, Metadata>]
        /// The keys whose bookmark bytes are no longer the ones held before.
        var invalidated: Set<Key>
        /// The records the table removed on its own.
        var evictions: [StoreEviction<Key, Metadata>]
    }

    enum Outcome: Sendable, Equatable {
        case superseded
        case unchanged
        case changed
    }

    private var records: [Key: Record] = [:]
    private(set) var order: [Key] = []
    private var generations: [Key: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private var invalidated: Set<Key> = []
    private var modified: Set<Key> = []
    private var evictions: [StoreEviction<Key, Metadata>] = []

    init(_ loaded: [Record] = []) {
        for record in loaded where records[record.key] == nil {
            records[record.key] = record
            order.append(record.key)
        }
    }

    var orderedRecords: [Record] {
        order.compactMap { records[$0] }
    }

    subscript(key: Key) -> Record? {
        records[key]
    }

    func snapshot(_ key: Key) -> Snapshot? {
        records[key].map { Snapshot(record: $0, generation: generations[key, default: 0]) }
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        records[snapshot.key] != nil && generations[snapshot.key, default: 0] == snapshot.generation
    }

    func paths(excluding key: Key) -> [String] {
        orderedRecords.filter { $0.key != key }.map(\.lastKnownPath)
    }

    func duplicate(of identity: FileIdentity?, path: NormalizedPath, excluding key: Key) -> Record? {
        orderedRecords.first { record in
            guard record.key != key else { return false }
            if let identity, let other = record.fileIdentity {
                return identity == other
            }
            return path.matches(NormalizedPath(record.lastKnownPath))
        }
    }

    func key(matching identity: FileIdentity?, path: NormalizedPath) -> Key? {
        let records = orderedRecords
        if let identity, let match = records.first(where: { $0.fileIdentity == identity }) {
            return match.key
        }
        return records.first { path.matches(NormalizedPath($0.lastKnownPath)) }?.key
    }

    func keysContaining(_ path: NormalizedPath) -> [Key] {
        orderedRecords
            .map { (key: $0.key, path: NormalizedPath($0.lastKnownPath, isCaseSensitive: path.isCaseSensitive)) }
            .filter { $0.path.contains(path) }
            .sorted { $0.path.components.count > $1.path.components.count }
            .map(\.key)
    }

    mutating func put(_ record: Record, ordering: RecordOrdering) {
        if records[record.key] == nil {
            order.append(record.key)
        }
        records[record.key] = record
        modified.insert(record.key)
        invalidate(record.key)
        promote(record.key, ordering: ordering)
    }

    mutating func replaceItem(
        of key: Key,
        data: BookmarkData?,
        kind: BookmarkKind,
        path: String,
        identity: FileIdentity?,
        status: RecordStatus = .available,
        date: Date,
        usedAt: Date? = nil,
        ordering: RecordOrdering
    ) -> Record? {
        guard var record = records[key] else { return nil }
        record.data = data
        record.kind = kind
        record.lastKnownPath = path
        record.fileIdentity = identity ?? record.fileIdentity
        record.status = status
        record.refreshedAt = date
        record.lastUsedAt = usedAt ?? record.lastUsedAt
        records[key] = record
        modified.insert(key)
        invalidate(key)
        promote(key, ordering: ordering)
        return record
    }

    mutating func updateMetadata(of key: Key, _ change: (inout Metadata) -> Void) -> Bool {
        guard records[key] != nil else { return false }
        change(&records[key]!.metadata)
        modified.insert(key)
        return true
    }

    /// Records a use of `key` at `date`, moving it to the front of a most-recently-used order.
    mutating func markUsed(_ key: Key, at date: Date, ordering: RecordOrdering) -> Bool {
        guard records[key] != nil else { return false }
        if records[key]?.lastUsedAt != date {
            records[key]?.lastUsedAt = date
            modified.insert(key)
        }
        promote(key, ordering: ordering)
        return true
    }

    mutating func setPinned(_ key: Key, _ isPinned: Bool) -> Bool {
        guard let record = records[key] else { return false }
        if record.isPinned != isPinned {
            records[key]?.isPinned = isPinned
            modified.insert(key)
        }
        return true
    }

    /// Sets where `key`'s item is. A path-only record, whose path is all the store has, also
    /// takes `identity` and forgets its status, and resolutions of its old path no longer
    /// commit.
    mutating func setLastKnownPath(_ key: Key, to path: String, identity: FileIdentity?) -> Record? {
        guard var record = records[key] else { return nil }
        guard record.lastKnownPath != path else { return record }
        record.lastKnownPath = path
        if !record.hasBookmark {
            record.fileIdentity = identity
            record.status = .unknown
            invalidate(key)
        }
        records[key] = record
        modified.insert(key)
        return record
    }

    mutating func remove(_ key: Key) -> Bool {
        guard records.removeValue(forKey: key) != nil else { return false }
        order.removeAll { $0 == key }
        invalidate(key)
        return true
    }

    mutating func removeAll() {
        order.forEach { _ = remove($0) }
    }

    /// Removes the records `predicate` matches, returning their keys in order.
    mutating func removeAll(where predicate: (Record) -> Bool) -> [Key] {
        let matching = orderedRecords.filter(predicate).map(\.key)
        matching.forEach { _ = remove($0) }
        return matching
    }

    mutating func move(_ key: Key, to index: Int) -> Bool {
        guard let current = order.firstIndex(of: key) else { return false }
        order.remove(at: current)
        order.insert(key, at: min(max(index, 0), order.count))
        return true
    }

    mutating func promote(_ key: Key, ordering: RecordOrdering) {
        guard ordering == .mostRecentlyUsed, records[key] != nil else { return }
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
    }

    /// Removes records beyond `limit` in the order `policy` gives, never `key` or a record the
    /// policy protects, and notes them as evictions.
    mutating func evict(beyond limit: Int?, keeping key: Key, ordering: RecordOrdering, policy: EvictionPolicy = .storeOrder) {
        guard let limit, order.count > limit else { return }
        let candidates = order.enumerated().filter { $0.element != key }
        let described = candidates.map { EvictionCandidate(records[$0.element]!, position: $0.offset, ordering: ordering) }
        let excess = order.count - limit
        for index in policy.evictionOrder(of: described).prefix(excess) {
            let victim = candidates[index].element
            if let record = records[victim] {
                evictions.append(StoreEviction(record: record, reason: .limit))
            }
            _ = remove(victim)
        }
    }

    mutating func applySuccess(_ resolution: Resolution, to snapshot: Snapshot) -> Outcome {
        // Stored bytes equal to the refreshed ones mean a caller sharing this resolution
        // already committed it. A path-only record takes the bookmark just made for it.
        guard
            isCurrent(snapshot),
            var record = records[snapshot.key],
            record.data == resolution.originalData || record.data == resolution.refreshedData
                || (!record.hasBookmark && resolution.madeKind != nil)
        else {
            return .superseded
        }
        let before = record
        if !record.hasBookmark, let kind = resolution.madeKind {
            record.data = resolution.refreshedData ?? resolution.originalData
            record.kind = kind
            record.refreshedAt = resolution.date
        } else if let refreshed = resolution.refreshedData, record.data != refreshed {
            record.data = refreshed
            record.refreshedAt = resolution.date
        }
        record.lastKnownPath = resolution.path
        record.fileIdentity = resolution.identity ?? record.fileIdentity
        record.status = .available
        guard !Self.sameState(before, record) else { return .unchanged }
        records[snapshot.key] = record
        modified.insert(snapshot.key)
        return .changed
    }

    mutating func applyFailure(
        _ failure: BookmarkFailure,
        to snapshot: Snapshot,
        dropping: Bool,
        at date: Date
    ) {
        guard isCurrent(snapshot), var record = records[snapshot.key] else { return }
        if dropping {
            _ = remove(snapshot.key)
            evictions.append(StoreEviction(record: record, reason: .failure(failure)))
        } else if record.status.failure != failure {
            record.status = .unavailable(failure, since: date)
            records[snapshot.key] = record
            modified.insert(snapshot.key)
        }
    }

    /// Replaces the records with `loaded`, noting what changed.
    ///
    /// With `keepingKnownState`, a loaded record whose bytes and kind are the ones this table
    /// holds takes this table's status, identity, path and dates, for a persistence that
    /// can't store them.
    mutating func replaceAll(with loaded: [Record], keepingKnownState: Bool = false) {
        let fresh = RecordTable(keepingKnownState ? loaded.map(withKnownState) : loaded)
        for key in order where fresh.records[key] == nil {
            invalidate(key)
        }
        for key in fresh.order {
            let new = fresh.records[key]!
            guard let old = records[key] else {
                invalidate(key)
                continue
            }
            if old.data != new.data || old.kind != new.kind {
                invalidate(key)
            }
            if !Self.sameState(old, new) || old.metadata != new.metadata {
                modified.insert(key)
            }
        }
        records = fresh.records
        order = fresh.order
    }

    private func withKnownState(_ loaded: Record) -> Record {
        guard let known = records[loaded.key], known.data == loaded.data, known.kind == loaded.kind else {
            return loaded
        }
        var record = loaded
        record.lastKnownPath = known.lastKnownPath
        record.fileIdentity = known.fileIdentity
        record.status = known.status
        record.createdAt = known.createdAt
        record.refreshedAt = known.refreshedAt
        record.lastUsedAt = known.lastUsedAt
        record.isPinned = known.isPinned
        return record
    }

    /// What changed since `old`, which must be this table before the current transaction.
    mutating func takeChanges(since old: RecordTable) -> Changes {
        defer {
            invalidated = []
            modified = []
            evictions = []
        }
        var changes: [StoreChange<Key, Metadata>] = old.order.filter { records[$0] == nil }.map { .removed($0) }
        changes += order.compactMap { key in old.records[key] == nil ? records[key].map { .added($0) } : nil }
        changes += order.compactMap { key in
            old.records[key] != nil && modified.contains(key) ? records[key].map { .updated($0) } : nil
        }
        let expectedOrder = old.order.filter { records[$0] != nil } + order.filter { old.records[$0] == nil }
        if expectedOrder != order {
            changes.append(.reordered(order))
        }
        return Changes(changes: changes, invalidated: invalidated, evictions: evictions)
    }

    private mutating func invalidate(_ key: Key) {
        nextGeneration += 1
        generations[key] = nextGeneration
        invalidated.insert(key)
    }

    private static func sameState(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.data == rhs.data && lhs.kind == rhs.kind && lhs.lastKnownPath == rhs.lastKnownPath
            && lhs.fileIdentity == rhs.fileIdentity && lhs.status == rhs.status
            && lhs.createdAt == rhs.createdAt && lhs.refreshedAt == rhs.refreshedAt
            && lhs.lastUsedAt == rhs.lastUsedAt && lhs.isPinned == rhs.isPinned
    }

    static func sameRecord(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.key == rhs.key && sameState(lhs, rhs) && lhs.metadata == rhs.metadata
    }
}
