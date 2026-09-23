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
        data: BookmarkData,
        kind: BookmarkKind,
        path: String,
        identity: FileIdentity?,
        date: Date,
        ordering: RecordOrdering
    ) -> Record? {
        guard var record = records[key] else { return nil }
        record.data = data
        record.kind = kind
        record.lastKnownPath = path
        record.fileIdentity = identity ?? record.fileIdentity
        record.status = .available
        record.refreshedAt = date
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

    mutating func remove(_ key: Key) -> Bool {
        guard records.removeValue(forKey: key) != nil else { return false }
        order.removeAll { $0 == key }
        invalidate(key)
        return true
    }

    mutating func removeAll() {
        order.forEach { _ = remove($0) }
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

    mutating func evict(beyond limit: Int?, keeping key: Key) {
        guard let limit else { return }
        while order.count > limit, let victim = order.last(where: { $0 != key }) {
            _ = remove(victim)
        }
    }

    mutating func applySuccess(_ resolution: Resolution, to snapshot: Snapshot) -> Outcome {
        guard isCurrent(snapshot), var record = records[snapshot.key], record.data == resolution.originalData else {
            return .superseded
        }
        let before = record
        if let refreshed = resolution.refreshedData {
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
        } else if record.status.failure != failure {
            record.status = .unavailable(failure, since: date)
            records[snapshot.key] = record
            modified.insert(snapshot.key)
        }
    }

    mutating func replaceAll(with loaded: [Record]) {
        let fresh = RecordTable(loaded)
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

    /// The changes since `old`, which must be this table before the current transaction, and
    /// the keys whose bookmark bytes are no longer the ones `old` held.
    mutating func takeChanges(since old: RecordTable) -> (changes: [StoreChange<Key, Metadata>], invalidated: Set<Key>) {
        defer {
            invalidated = []
            modified = []
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
        return (changes, invalidated)
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
    }

    static func sameRecord(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.key == rhs.key && sameState(lhs, rhs) && lhs.metadata == rhs.metadata
    }
}
