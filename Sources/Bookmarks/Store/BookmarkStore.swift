public import Foundation
import os
import Synchronization

/// A keyed collection of bookmarks with balanced access, stale refresh and pluggable storage.
///
/// Keys are the app's stable identifiers and never change when bookmark bytes are refreshed
/// or re-granted. Records that fail to resolve are kept and marked unavailable unless the
/// ``StorePolicy/failureHandling`` says otherwise, and every write includes them.
///
/// Changes are serialised, and persistence and system calls run on the bookmark executor, so
/// nothing blocks the caller. Reads never wait for a save in progress. Records load on first
/// use; call ``load()`` to load them earlier.
public actor BookmarkStore<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable> {
    public typealias Record = BookmarkRecord<Key, Metadata>
    public typealias Failure = BookmarkStoreError<Key>
    typealias Table = RecordTable<Key, Metadata>

    /// The bookmark service the store uses.
    public nonisolated let service: BookmarkService
    /// The kind new bookmarks are created with.
    public nonisolated let kind: BookmarkKind
    /// How the store behaves.
    public nonisolated let policy: StorePolicy
    /// The registry that balances access for the store's keys.
    public nonisolated let registry: AccessRegistry<Key>

    private let persistence: any BookmarkPersistence<Key, Metadata>
    private var table = Table()
    private var isLoaded = false
    private var loading: Task<Result<[Record], PersistenceError>, Never>?
    private let writes = AsyncLock()
    private let resolutions = SingleFlight<Flight, ResolvedBookmark>()
    private let observers = Mutex<[UUID: AsyncStream<StoreChange<Key>>.Continuation]>([:])
    private let now: @Sendable () -> Date

    private struct Flight: Hashable, Sendable {
        let key: Key
        let generation: UInt64
    }

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - persistence: Where records are loaded from and saved to.
    ///   - kind: The kind of new bookmarks. Defaults to the environment's persistent default.
    ///   - policy: How the store behaves.
    ///   - service: The bookmark service.
    ///   - now: The clock used for record dates.
    public init(
        persistence: some BookmarkPersistence<Key, Metadata>,
        kind: BookmarkKind? = nil,
        policy: StorePolicy = .default,
        service: BookmarkService = BookmarkService(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.service = service
        self.kind = kind ?? service.defaultKind
        self.policy = policy
        self.now = now
        registry = AccessRegistry(engine: service.engine)
    }

    deinit {
        observers.withLock { $0.values.forEach { $0.finish() } }
    }

    // MARK: - Loading

    /// Loads the stored records on the bookmark executor. Does nothing once they're loaded.
    public func load() async throws(Failure) {
        guard !isLoaded else { return }
        let task = loading ?? Task { await loadFromPersistence() }
        loading = task
        let result = await task.value
        loading = nil
        guard !isLoaded else { return }
        switch result {
        case .success(let records):
            table = Table(records)
            isLoaded = true
        case .failure(let error):
            throw .persistence(error)
        }
    }

    /// Replaces the records with what the persistence holds now, such as after another
    /// process changed them.
    public func reload() async throws(Failure) {
        try await load()
        let (changes, invalidated) = try await writes.withLock { () async throws(Failure) in
            let records: [Record]
            switch await loadFromPersistence() {
            case .success(let loaded): records = loaded
            case .failure(let error): throw .persistence(error)
            }
            let changes = table.replaceAll(with: records)
            return (changes, table.takeInvalidated())
        }
        finish(changes, invalidating: invalidated)
    }

    // MARK: - Reading

    /// All records in the policy's order, including unavailable ones.
    public func records() async throws(Failure) -> [Record] {
        try await load()
        return table.orderedRecords
    }

    /// The record for `key`, or `nil` when there is none.
    public func record(_ key: Key) async throws(Failure) -> Record? {
        try await load()
        return table[key]
    }

    /// The stored keys in the policy's order.
    public func keys() async throws(Failure) -> [Key] {
        try await load()
        return table.order
    }

    /// Whether a record exists for `key`.
    public func contains(_ key: Key) async throws(Failure) -> Bool {
        try await load()
        return table[key] != nil
    }

    /// The key whose item is `url`, matched by file identity first and by path second.
    public func key(matching url: URL) async throws(Failure) -> Key? {
        try await load()
        let identity = await identity(of: url)
        return table.key(matching: identity, path: NormalizedPath(url))
    }

    /// A stream of changes to the records. Each call returns a new stream.
    ///
    /// The default policy buffers every change until it's read; pass a bounded policy for
    /// subscribers that may stop reading without cancelling.
    public nonisolated func changes(
        bufferingPolicy: AsyncStream<StoreChange<Key>>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<StoreChange<Key>> {
        let (stream, continuation) = AsyncStream<StoreChange<Key>>.makeStream(bufferingPolicy: bufferingPolicy)
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
        let context = try await validationContext(excluding: key, relinquishing: grant)
        let resolved = try await adopt(grant, context: context)
        let path = NormalizedPath(resolved.url).string
        let timestamp = now()
        return try await mutate { table throws(Failure) in
            if policy.duplicates != .allow,
               let existing = table.duplicate(of: resolved.fileIdentity, path: path, excluding: key) {
                guard policy.duplicates == .returnExisting else { throw .duplicate(of: existing.key) }
                let moved = table.promote(existing.key, ordering: policy.ordering)
                return (existing, moved ? [.updated(existing.key)] : [])
            }
            let previous = table[key]
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
            let change = table.put(record, ordering: policy.ordering)
            let evicted = table.evict(beyond: policy.limit, keeping: key)
            return (record, [change] + evicted.map(StoreChange.removed))
        }
    }

    /// Replaces the bookmark for `key` with a newly granted item, keeping the key and metadata.
    ///
    /// The grant is relinquished whether or not re-granting succeeds.
    @discardableResult
    public func regrant(_ key: Key, with grant: Grant) async throws(Failure) -> Record {
        let context = try await validationContext(excluding: key, relinquishing: grant)
        guard let existing = table[key] else {
            service.relinquish(grant)
            throw .notFound(key)
        }
        let resolved = try await adopt(grant, context: context)
        if policy.requiresSameItemOnRegrant, let expected = existing.fileIdentity, resolved.fileIdentity != expected {
            throw .differentItem(key)
        }
        let path = NormalizedPath(resolved.url).string
        let timestamp = now()
        return try await mutate { table throws(Failure) in
            guard let record = table.replaceItem(
                of: key,
                data: resolved.data,
                kind: kind,
                path: path,
                identity: resolved.fileIdentity,
                date: timestamp,
                ordering: policy.ordering
            ) else {
                throw .notFound(key)
            }
            return (record, [.updated(key)])
        }
    }

    /// Removes the record for `key`. Active leases keep access until they end.
    ///
    /// - Returns: Whether a record was removed.
    @discardableResult
    public func forget(_ key: Key) async throws(Failure) -> Bool {
        try await mutate { table throws(Failure) in
            table.remove(key) ? (true, [.removed(key)]) : (false, [])
        }
    }

    /// Removes every record. Active leases keep access until they end.
    public func removeAll() async throws(Failure) {
        try await mutate { table throws(Failure) in
            ((), table.removeAll().map(StoreChange.removed))
        }
    }

    /// Changes the metadata stored for `key`.
    public func updateMetadata(_ key: Key, _ change: sending (inout Metadata) -> Void) async throws(Failure) {
        try await mutate { table throws(Failure) in
            guard table.updateMetadata(of: key, change) else { throw .notFound(key) }
            return ((), [.updated(key)])
        }
    }

    /// Moves `key` to `index` in the store's order.
    public func move(_ key: Key, to index: Int) async throws(Failure) {
        try await mutate { table throws(Failure) in
            guard table.move(key, to: index) else { throw .notFound(key) }
            return ((), [.updated(key)])
        }
    }

    // MARK: - Access

    /// A lease on the item stored under `key`, resolving and refreshing the bookmark if needed.
    ///
    /// While any lease for `key` is active, further leases share its access without resolving
    /// again.
    public func lease(_ key: Key) async throws(Failure) -> AccessLease {
        try await load()
        if let lease = registry.activeLease(for: key) {
            await touch(key)
            return lease
        }
        for _ in 0..<3 {
            let snapshot = try snapshot(key)
            let resolved = try await resolve(snapshot)
            let access = resolved.beginAccess()
            defer { access.end() }
            let identity = await identity(of: access.url)
            guard await commit(resolved, identity: identity, for: snapshot) else { continue }
            let lease = registry.lease(for: key, resolved: resolved)
            await touch(key)
            return lease
        }
        throw .changedDuringAccess(key)
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

    /// A lease on the stored item that contains `url`, or `nil` when no stored item does.
    ///
    /// The deepest containing item that resolves wins; when none resolves, the deepest one's
    /// error is thrown. Use ``AccessLease/url(forDescendant:)`` to reach `url` through the
    /// lease, so files inside a stored folder share the folder's access.
    public func lease(covering url: URL) async throws(Failure) -> AccessLease? {
        try await load()
        let candidates = table.keysContaining(NormalizedPath(url))
        var deepestFailure: Failure?
        for key in candidates {
            do {
                return try await lease(key)
            } catch {
                deepestFailure = deepestFailure ?? error
            }
        }
        if let deepestFailure { throw deepestFailure }
        return nil
    }

    /// A new lease sharing the active access for `key`, or `nil` when `key` isn't leased.
    public nonisolated func activeLease(for key: Key) -> AccessLease? {
        registry.activeLease(for: key)
    }

    /// Stops all access immediately. Call at termination, after file readers have stopped.
    public nonisolated func endAllAccess() {
        registry.endAll()
    }

    // MARK: - Checking

    /// Checks whether the item stored under `key` is reachable, without mounting, UI or access.
    public func availability(_ key: Key) async throws(Failure) -> Availability {
        try await load()
        guard let record = table[key] else { throw .notFound(key) }
        return await service.availability(of: record.data, kind: record.kind)
    }

    /// Resolves records that aren't known to be available and updates their status.
    ///
    /// Call it when a volume mounts or the app becomes active.
    ///
    /// - Returns: The keys that resolved.
    @discardableResult
    public func refreshStatuses() async throws(Failure) -> [Key] {
        try await load()
        let candidates = table.order.compactMap { table.snapshot($0) }.filter { $0.record.status != .available }
        var recovered: [Key] = []
        for snapshot in candidates {
            if let resolved = try? await resolve(snapshot), await commit(resolved, identity: nil, for: snapshot) {
                recovered.append(snapshot.key)
            }
        }
        return recovered
    }

    // MARK: - Internals

    nonisolated func pendingResolutionCallers(for key: Key) -> Int {
        resolutions.callers { $0.key == key }
    }

    private func adopt(_ grant: Grant, context: ValidationContext) async throws(Failure) -> ResolvedBookmark {
        do {
            return try await service.adopt(grant, kind: kind, validators: policy.validators, context: context)
        } catch {
            throw .bookmark(error)
        }
    }

    private func resolve(_ snapshot: Table.Snapshot) async throws(Failure) -> ResolvedBookmark {
        let policy = ResolutionPolicy(mounting: policy.mounting, allowsUI: policy.allowsUI)
        let service = service
        let record = snapshot.record
        do {
            return try await resolutions.run(Flight(key: snapshot.key, generation: snapshot.generation)) {
                try await service.resolve(record.data, kind: record.kind, policy: policy)
            }
        } catch let error as BookmarkError {
            await commit(error.failure, for: snapshot)
            throw .bookmark(error)
        } catch {
            throw .bookmark(BookmarkError(.cancelled))
        }
    }

    private func commit(_ resolved: ResolvedBookmark, identity: FileIdentity?, for snapshot: Table.Snapshot) async -> Bool {
        let resolution = Table.Resolution(
            originalData: resolved.originalData,
            refreshedData: resolved.refreshedData,
            path: NormalizedPath(resolved.url).string,
            identity: identity,
            date: now()
        )
        do {
            return try await mutate { table throws(Failure) in
                switch table.applySuccess(resolution, to: snapshot) {
                case .superseded: (false, [])
                case .unchanged: (true, [])
                case .changed: (true, [.updated(snapshot.key)])
                }
            }
        } catch {
            Log.store.error("Saving a resolved bookmark failed: \(String(describing: error), privacy: .private)")
            return table.isCurrent(snapshot)
        }
    }

    private func commit(_ failure: BookmarkFailure, for snapshot: Table.Snapshot) async {
        let dropping = policy.failureHandling.drops(failure)
        let timestamp = now()
        do {
            try await mutate { table throws(Failure) in
                ((), table.applyFailure(failure, to: snapshot, dropping: dropping, at: timestamp).map { [$0] } ?? [])
            }
        } catch {
            Log.store.error("Saving a bookmark's status failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func touch(_ key: Key) async {
        guard policy.ordering == .mostRecentlyUsed else { return }
        _ = try? await mutate { table throws(Failure) in
            ((), table.promote(key, ordering: policy.ordering) ? [.updated(key)] : [])
        }
    }

    private func identity(of url: URL) async -> FileIdentity? {
        let engine = service.engine
        return try? await service.executor.run { engine.fileIdentity(of: url) }
    }

    private func snapshot(_ key: Key) throws(Failure) -> Table.Snapshot {
        guard let snapshot = table.snapshot(key) else { throw .notFound(key) }
        return snapshot
    }

    private func validationContext(excluding key: Key, relinquishing grant: Grant) async throws(Failure) -> ValidationContext {
        do {
            try await load()
            return ValidationContext(existingPaths: table.paths(excluding: key))
        } catch {
            service.relinquish(grant)
            throw error
        }
    }

    @discardableResult
    private func mutate<T>(
        _ body: (inout Table) throws(Failure) -> (T, [StoreChange<Key>])
    ) async throws(Failure) -> T {
        try await load()
        let (result, changes, invalidated) = try await writes.withLock { () async throws(Failure) in
            var draft = table
            let (result, changes) = try body(&draft)
            let invalidated = draft.takeInvalidated()
            if !changes.isEmpty {
                try await save(draft.orderedRecords)
            }
            table = draft
            return (result, changes, invalidated)
        }
        finish(changes, invalidating: invalidated)
        return result
    }

    private nonisolated func finish(_ changes: [StoreChange<Key>], invalidating keys: Set<Key>) {
        keys.forEach(registry.detach)
        guard !changes.isEmpty else { return }
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            changes.forEach { continuation.yield($0) }
        }
    }

    private func loadFromPersistence() async -> Result<[Record], PersistenceError> {
        let persistence = persistence
        do {
            return .success(try await service.executor.perform { () throws(PersistenceError) in try persistence.load() })
        } catch {
            return .failure(error)
        }
    }

    private func save(_ records: [Record]) async throws(Failure) {
        let persistence = persistence
        do {
            try await service.executor.perform { () throws(PersistenceError) -> Void in try persistence.save(records) }
        } catch {
            throw .persistence(error)
        }
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
