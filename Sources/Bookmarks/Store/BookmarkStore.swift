public import Foundation
import os
import Synchronization

/// A keyed collection of bookmarks with balanced access, stale refresh and pluggable storage.
///
/// Keys are the app's stable identifiers and never change when bookmark bytes are refreshed
/// or re-granted. Records that fail to resolve are kept and marked unavailable unless the
/// ``StorePolicy/failureHandling`` says otherwise, and every write includes them.
///
/// The store is safe to use from any thread. Reads and metadata updates are synchronous;
/// anything that talks to the system is `async` and runs on the bookmark executor.
public final class BookmarkStore<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: Sendable {
    public typealias Record = BookmarkRecord<Key, Metadata>
    public typealias Failure = BookmarkStoreError<Key>

    /// The bookmark service the store uses.
    public let bookmarks: Bookmarks
    /// The kind new bookmarks are created with.
    public let kind: BookmarkKind
    /// How the store behaves.
    public let policy: StorePolicy
    /// The registry that balances access for the store's keys.
    public let registry: AccessRegistry<Key>

    private let persistence: any BookmarkPersistence<Key, Metadata>
    private let state = Mutex(State())
    private let resolutions = SingleFlight<Key, ResolvedBookmark>()
    private let observers = Mutex<[UUID: AsyncStream<StoreChange<Key>>.Continuation]>([:])
    private let now: @Sendable () -> Date

    private struct Snapshot: Sendable {
        let record: Record
        let generation: UInt64
    }

    private struct State {
        var records: [Key: Record] = [:]
        var order: [Key] = []
        var loaded = false
        var generations: [Key: UInt64] = [:]
        var nextGeneration: UInt64 = 0

        var orderedRecords: [Record] {
            order.compactMap { records[$0] }
        }

        func snapshot(_ key: Key) -> Snapshot? {
            records[key].map { Snapshot(record: $0, generation: generations[key, default: 0]) }
        }

        mutating func bump(_ key: Key) {
            nextGeneration += 1
            generations[key] = nextGeneration
        }
    }

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - persistence: Where records are loaded from and saved to.
    ///   - kind: The kind of new bookmarks. Defaults to the environment's persistent default.
    ///   - policy: How the store behaves.
    ///   - bookmarks: The bookmark service.
    ///   - now: The clock used for record dates.
    public init(
        persistence: some BookmarkPersistence<Key, Metadata>,
        kind: BookmarkKind? = nil,
        policy: StorePolicy = .default,
        bookmarks: Bookmarks = Bookmarks(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.bookmarks = bookmarks
        self.kind = kind ?? bookmarks.defaultKind
        self.policy = policy
        self.now = now
        registry = AccessRegistry(engine: bookmarks.engine)
    }

    deinit {
        observers.withLock { $0.values.forEach { $0.finish() } }
    }

    // MARK: - Reading

    /// All records in the policy's order, including unavailable ones.
    public func records() throws(Failure) -> [Record] {
        try read { $0.orderedRecords }
    }

    /// The record for `key`, or `nil` when there is none.
    public func record(_ key: Key) throws(Failure) -> Record? {
        try read { $0.records[key] }
    }

    /// The stored keys in the policy's order.
    public func keys() throws(Failure) -> [Key] {
        try read { $0.order }
    }

    /// Whether a record exists for `key`.
    public func contains(_ key: Key) throws(Failure) -> Bool {
        try read { $0.records[key] != nil }
    }

    /// The key whose item is `url`, matched by file identity first and by path second.
    public func key(matching url: URL) async throws(Failure) -> Key? {
        let engine = bookmarks.engine
        let identity = try? await bookmarks.executor.run { engine.fileIdentity(of: url) }
        let path = Self.normalizedPath(url)
        return try read { state in
            if let identity, let match = state.orderedRecords.first(where: { $0.fileIdentity == identity }) {
                return match.key
            }
            return state.orderedRecords.first { Self.normalizedPath(URL(filePath: $0.lastKnownPath)) == path }?.key
        }
    }

    /// A stream of changes to the records. Each call returns a new stream.
    public func changes() -> AsyncStream<StoreChange<Key>> {
        let (stream, continuation) = AsyncStream<StoreChange<Key>>.makeStream()
        let id = UUID()
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - Adding and removing

    /// Adopts a granted item and stores it under `key`, replacing any record for `key`.
    ///
    /// The grant is relinquished whether or not adding succeeds.
    @discardableResult
    public func add(_ grant: Grant, key: Key, metadata: Metadata) async throws(Failure) -> Record {
        let context = try relinquishingOnFailure(grant) { () throws(Failure) in try validationContext(excluding: key) }
        let resolved: ResolvedBookmark
        do {
            resolved = try await bookmarks.adopt(grant, kind: kind, validators: policy.validators, context: context)
        } catch {
            throw .bookmark(error)
        }
        let path = Self.normalizedPath(resolved.unscopedURL)
        let timestamp = now()

        defer { registry.detach(key) }
        return try mutate { state throws(Failure) in
            if policy.duplicates != .allow,
               let existing = Self.duplicate(of: resolved.fileIdentity, path: path, excluding: key, in: state) {
                if policy.duplicates == .returnExisting {
                    return (existing, [])
                }
                throw .duplicate(of: existing.key)
            }
            let previous = state.records[key]
            let record = Record(
                key: key,
                data: resolved.data,
                kind: kind,
                lastKnownPath: path,
                fileIdentity: resolved.fileIdentity,
                status: .available,
                createdAt: previous?.createdAt ?? timestamp,
                refreshedAt: previous == nil ? nil : timestamp,
                metadata: metadata
            )
            state.records[key] = record
            if previous == nil {
                state.order.append(key)
            }
            state.bump(key)
            var changes: [StoreChange<Key>] = [previous == nil ? .added(key) : .updated(key)]
            moveToFrontIfNeeded(key, in: &state)
            changes += evictBeyondLimit(keeping: key, in: &state)
            return (record, changes)
        }
    }

    /// Replaces the bookmark for `key` with a newly granted item, keeping the key and metadata.
    ///
    /// The grant is relinquished whether or not re-granting succeeds.
    @discardableResult
    public func regrant(_ key: Key, with grant: Grant) async throws(Failure) -> Record {
        let (existing, context) = try relinquishingOnFailure(grant) { () throws(Failure) in
            guard let existing = try record(key) else { throw .notFound(key) }
            return (existing, try validationContext(excluding: key))
        }
        let resolved: ResolvedBookmark
        do {
            resolved = try await bookmarks.adopt(grant, kind: kind, validators: policy.validators, context: context)
        } catch {
            throw .bookmark(error)
        }
        if policy.requiresSameItemOnRegrant,
           let expected = existing.fileIdentity,
           resolved.fileIdentity != expected {
            throw .differentItem(key)
        }
        let timestamp = now()
        defer { registry.detach(key) }
        return try mutate { state throws(Failure) in
            guard var record = state.records[key] else { throw .notFound(key) }
            record.data = resolved.data
            record.kind = kind
            record.lastKnownPath = Self.normalizedPath(resolved.unscopedURL)
            record.fileIdentity = resolved.fileIdentity ?? record.fileIdentity
            record.status = .available
            record.refreshedAt = timestamp
            state.records[key] = record
            state.bump(key)
            moveToFrontIfNeeded(key, in: &state)
            return (record, [.updated(key)])
        }
    }

    /// Removes the record for `key`. Active leases keep access until they end.
    ///
    /// - Returns: Whether a record was removed.
    @discardableResult
    public func forget(_ key: Key) throws(Failure) -> Bool {
        try mutate { state throws(Failure) in
            guard state.records.removeValue(forKey: key) != nil else { return (false, []) }
            state.order.removeAll { $0 == key }
            state.bump(key)
            return (true, [.removed(key)])
        }
    }

    /// Removes every record. Active leases keep access until they end.
    public func removeAll() throws(Failure) {
        try mutate { state throws(Failure) in
            let keys = state.order
            state.records.removeAll()
            state.order.removeAll()
            keys.forEach { state.bump($0) }
            return ((), keys.map(StoreChange.removed))
        }
    }

    /// Changes the metadata stored for `key`.
    public func updateMetadata(_ key: Key, _ change: (inout Metadata) -> Void) throws(Failure) {
        try mutate { state throws(Failure) in
            guard var record = state.records[key] else { throw .notFound(key) }
            change(&record.metadata)
            state.records[key] = record
            return ((), [.updated(key)])
        }
    }

    /// Moves `key` to `index` in the store's order.
    public func move(_ key: Key, to index: Int) throws(Failure) {
        try mutate { state throws(Failure) in
            guard let current = state.order.firstIndex(of: key) else { throw .notFound(key) }
            state.order.remove(at: current)
            state.order.insert(key, at: min(max(index, 0), state.order.count))
            return ((), [.updated(key)])
        }
    }

    // MARK: - Access

    /// A lease on the item stored under `key`, resolving and refreshing the bookmark if needed.
    ///
    /// While any lease for `key` is active, further leases share its access without resolving
    /// again.
    public func lease(_ key: Key) async throws(Failure) -> AccessLease {
        if let lease = registry.activeLease(for: key) {
            touch(key)
            return lease
        }
        var attempts = 0
        while true {
            attempts += 1
            let snapshot = try snapshot(key)
            let resolved = try await resolve(snapshot.record, generation: snapshot.generation)
            guard let resolved else {
                if attempts < 3 { continue }
                throw .notFound(key)
            }
            let lease = registry.lease(for: key, url: resolved.unscopedURL)
            await updateIdentity(of: key, using: lease)
            touch(key)
            return lease
        }
    }

    /// Leases every key, runs `body` with their URLs, and ends the leases afterwards.
    ///
    /// Duplicate keys are leased once. If any lease fails, the ones already acquired end.
    nonisolated(nonsending) public func withAccess<T>(
        to keys: [Key],
        _ body: ([Key: URL]) async throws -> T
    ) async throws -> T {
        var leases: [Key: AccessLease] = [:]
        defer { leases.values.forEach { $0.end() } }
        for key in keys where leases[key] == nil {
            leases[key] = try await lease(key)
        }
        return try await body(leases.mapValues(\.url))
    }

    /// Leases one key, runs `body` with its URL, and ends the lease afterwards.
    nonisolated(nonsending) public func withAccess<T>(to key: Key, _ body: (URL) async throws -> T) async throws -> T {
        let lease = try await lease(key)
        defer { lease.end() }
        return try await body(lease.url)
    }

    /// A new lease sharing the active access for `key`, or `nil` when `key` isn't leased.
    public func activeLease(for key: Key) -> AccessLease? {
        registry.activeLease(for: key)
    }

    /// Stops all access immediately. Call at termination, after file readers have stopped.
    public func endAllAccess() {
        registry.endAll()
    }

    // MARK: - Checking

    /// Checks whether the item stored under `key` is reachable, without mounting, UI or access.
    public func availability(_ key: Key) async throws(Failure) -> Availability {
        guard let record = try record(key) else { throw .notFound(key) }
        return await bookmarks.availability(of: record.data, kind: record.kind)
    }

    /// Resolves records that aren't known to be available and updates their status.
    ///
    /// Call it when a volume mounts or the app becomes active.
    ///
    /// - Returns: The keys that resolved.
    @discardableResult
    public func refreshStatuses() async throws(Failure) -> [Key] {
        let candidates = try read { state in
            state.order.compactMap { state.snapshot($0) }.filter { $0.record.status != .available }
        }
        var recovered: [Key] = []
        for candidate in candidates {
            if (try? await resolve(candidate.record, generation: candidate.generation)) != nil {
                recovered.append(candidate.record.key)
            }
        }
        return recovered
    }

    // MARK: - Internals

    private func resolve(_ record: Record, generation: UInt64) async throws(Failure) -> ResolvedBookmark? {
        var policy = policy.resolution
        policy.startsImplicitAccess = false
        let resolution = policy
        let bookmarks = bookmarks
        let resolved: ResolvedBookmark
        do {
            resolved = try await resolutions.run(record.key) {
                try await bookmarks.resolve(record.data, kind: record.kind, policy: resolution)
            }
        } catch let error as BookmarkError {
            recordFailure(error.failure, for: record.key, generation: generation)
            throw .bookmark(error)
        } catch {
            throw .bookmark(BookmarkError(.cancelled))
        }
        return recordSuccess(resolved, for: record.key, generation: generation) ? resolved : nil
    }

    private func recordSuccess(_ resolved: ResolvedBookmark, for key: Key, generation: UInt64) -> Bool {
        let timestamp = now()
        do {
            return try mutate { state throws(Failure) in
                guard state.generations[key, default: 0] == generation, var record = state.records[key] else {
                    return (false, [])
                }
                let before = record
                if let refreshed = resolved.refreshedData, record.data == resolved.originalData {
                    record.data = refreshed
                    record.refreshedAt = timestamp
                }
                record.lastKnownPath = Self.normalizedPath(resolved.unscopedURL)
                record.status = .available
                guard !Self.same(before, record) else { return (true, []) }
                state.records[key] = record
                return (true, [.updated(key)])
            }
        } catch {
            Log.store.error("Saving a refreshed bookmark failed: \(String(describing: error), privacy: .public)")
            return (try? read { $0.generations[key, default: 0] == generation && $0.records[key] != nil }) ?? false
        }
    }

    private func recordFailure(_ failure: BookmarkFailure, for key: Key, generation: UInt64) {
        guard failure != .cancelled else { return }
        let timestamp = now()
        do {
            try mutate { state throws(Failure) in
                guard state.generations[key, default: 0] == generation, var record = state.records[key] else {
                    return ((), [])
                }
                if policy.failureHandling.drops(failure) {
                    state.records[key] = nil
                    state.order.removeAll { $0 == key }
                    state.bump(key)
                    return ((), [.removed(key)])
                }
                if case .unavailable(let current, _) = record.status, current == failure {
                    return ((), [])
                }
                record.status = .unavailable(failure, since: timestamp)
                state.records[key] = record
                return ((), [.updated(key)])
            }
        } catch {
            Log.store.error("Saving a bookmark's status failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateIdentity(of key: Key, using lease: AccessLease) async {
        let engine = bookmarks.engine
        let url = lease.url
        guard let identity = try? await bookmarks.executor.run({ engine.fileIdentity(of: url) }) else { return }
        try? mutate { state throws(Failure) in
            guard var record = state.records[key], record.fileIdentity != identity else { return ((), []) }
            record.fileIdentity = identity
            state.records[key] = record
            return ((), [.updated(key)])
        }
    }

    private func touch(_ key: Key) {
        guard policy.ordering == .mostRecentlyUsed else { return }
        try? mutate { state throws(Failure) in
            guard state.order.first != key, state.records[key] != nil else { return ((), []) }
            moveToFrontIfNeeded(key, in: &state)
            return ((), [.updated(key)])
        }
    }

    private func moveToFrontIfNeeded(_ key: Key, in state: inout State) {
        guard policy.ordering == .mostRecentlyUsed else { return }
        state.order.removeAll { $0 == key }
        state.order.insert(key, at: 0)
    }

    private func evictBeyondLimit(keeping key: Key, in state: inout State) -> [StoreChange<Key>] {
        guard let limit = policy.limit else { return [] }
        var changes: [StoreChange<Key>] = []
        while state.order.count > limit, let victim = state.order.last(where: { $0 != key }) {
            state.order.removeAll { $0 == victim }
            state.records[victim] = nil
            state.bump(victim)
            changes.append(.removed(victim))
        }
        return changes
    }

    private func snapshot(_ key: Key) throws(Failure) -> Snapshot {
        guard let snapshot = try read({ $0.snapshot(key) }) else { throw .notFound(key) }
        return snapshot
    }

    private func relinquishingOnFailure<T>(_ grant: Grant, _ body: () throws(Failure) -> T) throws(Failure) -> T {
        do {
            return try body()
        } catch {
            bookmarks.relinquish(grant)
            throw error
        }
    }

    private func validationContext(excluding key: Key) throws(Failure) -> ValidationContext {
        let paths = try read { state in
            state.orderedRecords.filter { $0.key != key }.map(\.lastKnownPath)
        }
        return ValidationContext(existingPaths: paths)
    }

    private func read<T>(_ body: (State) -> T) throws(Failure) -> T {
        try state.withLock { state throws(Failure) in
            try loadIfNeeded(&state)
            return body(state)
        }
    }

    @discardableResult
    private func mutate<T>(_ body: (inout State) throws(Failure) -> (T, [StoreChange<Key>])) throws(Failure) -> T {
        let (result, changes) = try state.withLock { state throws(Failure) in
            try loadIfNeeded(&state)
            var draft = state
            let (result, changes) = try body(&draft)
            if !changes.isEmpty {
                do {
                    try persistence.save(draft.orderedRecords)
                } catch {
                    throw .persistence(PersistenceError(wrapping: error, as: .writeFailed))
                }
            }
            state = draft
            return (result, changes)
        }
        for change in changes {
            if case .removed(let key) = change {
                registry.detach(key)
            }
        }
        publish(changes)
        return result
    }

    private func loadIfNeeded(_ state: inout State) throws(Failure) {
        guard !state.loaded else { return }
        let loaded: [Record]
        do {
            loaded = try persistence.load()
        } catch {
            throw .persistence(PersistenceError(wrapping: error, as: .readFailed))
        }
        for record in loaded where state.records[record.key] == nil {
            state.records[record.key] = record
            state.order.append(record.key)
        }
        state.loaded = true
    }

    private func publish(_ changes: [StoreChange<Key>]) {
        guard !changes.isEmpty else { return }
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            changes.forEach { continuation.yield($0) }
        }
    }

    private static func duplicate(of identity: FileIdentity?, path: String, excluding key: Key, in state: State) -> Record? {
        state.orderedRecords.first { record in
            guard record.key != key else { return false }
            if let identity, let other = record.fileIdentity {
                return identity == other
            }
            return record.lastKnownPath == path
        }
    }

    private static func same(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.data == rhs.data && lhs.lastKnownPath == rhs.lastKnownPath && lhs.status == rhs.status
            && lhs.refreshedAt == rhs.refreshedAt && lhs.fileIdentity == rhs.fileIdentity
    }

    static func normalizedPath(_ url: URL) -> String {
        "/" + PathContainment.normalizedComponents(url).joined(separator: "/")
    }
}

extension BookmarkStore where Key == BookmarkID {
    /// Adopts a granted item and stores it under a new identifier.
    @discardableResult
    public func add(_ grant: Grant, metadata: Metadata) async throws(Failure) -> Record {
        try await add(grant, key: BookmarkID(), metadata: metadata)
    }
}

extension BookmarkStore where Metadata == NoMetadata {
    /// Adopts a granted item and stores it under `key`.
    @discardableResult
    public func add(_ grant: Grant, key: Key) async throws(Failure) -> Record {
        try await add(grant, key: key, metadata: NoMetadata())
    }
}

extension BookmarkStore where Key == BookmarkID, Metadata == NoMetadata {
    /// Adopts a granted item and stores it under a new identifier.
    @discardableResult
    public func add(_ grant: Grant) async throws(Failure) -> Record {
        try await add(grant, key: BookmarkID(), metadata: NoMetadata())
    }
}
