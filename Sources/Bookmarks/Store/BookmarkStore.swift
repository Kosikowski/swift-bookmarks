public import Foundation
import os
import Synchronization

/// A keyed collection of bookmarks with balanced access, stale refresh and pluggable storage.
///
/// Keys are the app's stable identifiers and never change when bookmark bytes are refreshed
/// or re-granted. Records that fail to resolve are kept and marked unavailable unless the
/// ``StorePolicy/failureHandling`` says otherwise, and every write includes them.
///
/// Changes are serialised, system calls run on the service's executor and persistence on the
/// store's own, so nothing blocks the caller and a hung volume can't hold up saving. Reads
/// never wait for a save in progress. Records load on first use; call ``load()`` to load
/// them earlier.
///
/// Every change is applied to the records as the persistence holds them at that moment, so
/// a store can share its persistence with another process. Changes the other process makes
/// reach this store, and its ``updates(bufferingPolicy:)`` subscribers, with the next change
/// or ``reload()``.
///
/// A persistence for a format that can't hold a record's status, identity, path or dates says
/// so with ``BookmarkPersistence/storesRecordState``, and the store keeps them in memory.
public actor BookmarkStore<Key: Hashable & Sendable, Metadata: Sendable & Equatable> {
    public typealias Record = BookmarkRecord<Key, Metadata>
    public typealias Failure = BookmarkStoreError<Key>
    typealias Table = RecordTable<Key, Metadata>

    /// The bookmark service the store uses.
    public nonisolated let service: BookmarkService
    /// The kind new bookmarks are created with.
    public nonisolated let kind: BookmarkKind
    /// How the store behaves.
    public nonisolated let policy: StorePolicy
    /// Checks that depend on the key an item is stored under, run with the policy's
    /// ``StorePolicy/validators`` whenever an item is added or re-granted.
    public nonisolated let validatorsForKey: @Sendable (Key) -> [any GrantValidator]
    nonisolated let registry: AccessRegistry<Key>

    private let persistence: any BookmarkPersistence<Key, Metadata>
    private let persistenceExecutor = BlockingExecutor(label: "swift-bookmarks.persistence", width: 1)
    private var table = Table()
    private var isLoaded = false
    private var loading: Task<Result<[Record], PersistenceError>, Never>?
    private let writes = AsyncLock()
    private var resolutions: [Flight: Resolution] = [:]
    private let observers = Mutex<[UUID: AsyncStream<StoreUpdate<Key, Metadata>>.Continuation]>([:])
    private let now: @Sendable () -> Date

    private struct Flight: Hashable, Sendable {
        let key: Key
        let generation: UInt64
    }

    private struct Resolution {
        let task: Task<Result<ResolvedBookmark, BookmarkError>, Never>
        var callers: Int
    }

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - persistence: Where records are loaded from and saved to.
    ///   - kind: The kind of new bookmarks. Defaults to the environment's persistent default.
    ///   - policy: How the store behaves.
    ///   - validatorsForKey: Checks for the item stored under a given key, such as
    ///     ``GrantValidator/covers(_:)`` for a key that names the folder it must cover. They
    ///     run after the policy's validators, on `add` and on `regrant` alike.
    ///   - service: The bookmark service.
    ///   - now: The clock used for record dates.
    public init(
        persistence: some BookmarkPersistence<Key, Metadata>,
        kind: BookmarkKind? = nil,
        policy: StorePolicy = .default,
        validatorsForKey: @escaping @Sendable (Key) -> [any GrantValidator] = { _ in [] },
        service: BookmarkService = BookmarkService(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.service = service
        self.kind = kind ?? service.defaultKind
        self.policy = policy
        self.validatorsForKey = validatorsForKey
        self.now = now
        registry = AccessRegistry(engine: service.engine, ledger: service.ledger)
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
        // Only the load this caller waited for is cleared, not one started after it failed.
        if loading == task {
            loading = nil
        }
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
        try await writes.withLock { () async throws(Failure) in
            let records: [Record]
            switch await loadFromPersistence() {
            case .success(let loaded): records = loaded
            case .failure(let error): throw .persistence(error)
            }
            let old = table
            table.replaceAll(with: records, keepingKnownState: !persistence.storesRecordState)
            let (changes, invalidated) = table.takeChanges(since: old)
            finish(changes, invalidating: invalidated)
        }
    }

    /// Reloads each time `changes` yields, until it ends or the calling task is cancelled.
    ///
    /// ```swift
    /// Task { await store.reload(on: persistence.changes()) }
    /// ```
    public func reload(on changes: AsyncStream<Void>) async {
        for await _ in changes {
            do {
                try await reload()
            } catch {
                Log.store.error("Reloading after an external change failed: \(String(describing: error), privacy: .private)")
            }
        }
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
        let (identity, isCaseSensitive) = await inspect(url)
        return table.key(matching: identity, path: NormalizedPath(url, isCaseSensitive: isCaseSensitive))
    }

    /// The records in order, then every change to them.
    ///
    /// The snapshot and the subscription are taken together, so no change falls between
    /// them. Each call returns a new stream. The default policy buffers every update until
    /// it's read; pass a bounded policy for subscribers that may stop reading without
    /// cancelling.
    public func updates(
        bufferingPolicy: AsyncStream<StoreUpdate<Key, Metadata>>.Continuation.BufferingPolicy = .unbounded
    ) async throws(Failure) -> AsyncStream<StoreUpdate<Key, Metadata>> {
        try await load()
        let (stream, continuation) = AsyncStream<StoreUpdate<Key, Metadata>>.makeStream(bufferingPolicy: bufferingPolicy)
        let id = UUID()
        continuation.yield(.snapshot(table.orderedRecords))
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - Adding and removing

    /// Adopts a granted item and stores it under `key`, replacing any record for `key`.
    ///
    /// When the item is already stored under another key, ``StorePolicy/duplicates`` decides
    /// what happens. The grant is relinquished whether or not adding succeeds.
    @discardableResult
    public func add(_ grant: Grant, key: Key, metadata: Metadata) async throws(Failure) -> Record {
        try await adding(grant, key: key, metadata: metadata).record
    }

    /// Adopts a granted item, stores it under `key` as ``add(_:key:metadata:)`` does, and
    /// leases it with the access adopting it resolved, so there is no second resolution that
    /// could fail after the record was saved.
    public func addAndLease(_ grant: Grant, key: Key, metadata: Metadata) async throws(Failure) -> (record: Record, lease: AccessLease) {
        let (record, resolved) = try await adding(grant, key: key, metadata: metadata)
        return (record, registry.lease(for: record.key, resolved: resolved))
    }

    private func adding(_ grant: Grant, key: Key, metadata: Metadata) async throws(Failure) -> (record: Record, resolved: ResolvedBookmark) {
        let context = try await prepare(grant, excluding: key)
        let resolved = try await adopt(grant, for: key, context: context)
        let record = try await insert(
            Item(data: resolved.data, kind: kind, location: resolved.handle.path, identity: resolved.fileIdentity, status: .available),
            key: key,
            metadata: metadata
        )
        return (record, resolved)
    }

    /// Stores a bookmark another store keeps, such as when an item moves from one list to
    /// another, under `key`, replacing any record for `key`.
    ///
    /// The bytes, kind, identity and status are taken as they are, and nothing is resolved,
    /// so an item that can't be reached now moves too. Validators don't run, because the item
    /// isn't accessed. Duplicates are handled as by ``add(_:key:metadata:)``; with
    /// ``DuplicateHandling/returnExisting`` the existing record takes the copied bytes and
    /// status.
    @discardableResult
    public func add<OtherKey, OtherMetadata>(
        copyOf other: BookmarkRecord<OtherKey, OtherMetadata>,
        key: Key,
        metadata: Metadata
    ) async throws(Failure) -> Record {
        if other.kind == .implicit, service.environment.supportsSecurityScope {
            throw .bookmark(BookmarkError(.unsupported(reason: Self.persistedImplicitReason)))
        }
        try await load()
        let (_, isCaseSensitive) = await inspect(URL(filePath: other.lastKnownPath), identity: false)
        return try await insert(
            Item(
                data: other.data,
                kind: other.kind,
                location: NormalizedPath(other.lastKnownPath, isCaseSensitive: isCaseSensitive),
                identity: other.fileIdentity,
                status: other.status
            ),
            key: key,
            metadata: metadata
        )
    }

    private struct Item: Sendable {
        let data: BookmarkData
        let kind: BookmarkKind
        let location: NormalizedPath
        let identity: FileIdentity?
        let status: RecordStatus
    }

    private func insert(_ item: Item, key: Key, metadata: Metadata) async throws(Failure) -> Record {
        let path = item.location.string
        let timestamp = now()
        return try await mutate { [policy] table throws(Failure) in
            if policy.duplicates != .allow,
               let existing = table.duplicate(of: item.identity, path: item.location, excluding: key) {
                guard policy.duplicates == .returnExisting else { throw .duplicate(of: existing.key) }
                return table.replaceItem(
                    of: existing.key,
                    data: item.data,
                    kind: item.kind,
                    path: path,
                    identity: item.identity,
                    status: item.status,
                    date: timestamp,
                    ordering: policy.ordering
                ) ?? existing
            }
            let previous = table[key]
            let record = Record(
                key: key,
                data: item.data,
                kind: item.kind,
                lastKnownPath: path,
                fileIdentity: item.identity,
                status: item.status,
                createdAt: previous?.createdAt ?? timestamp,
                refreshedAt: previous == nil ? nil : timestamp,
                metadata: metadata
            )
            table.put(record, ordering: policy.ordering)
            table.evict(beyond: policy.limit, keeping: key, ordering: policy.ordering)
            return record
        }
    }

    /// Replaces the bookmark for `key` with a newly granted item, keeping the key and metadata.
    ///
    /// Unless ``StorePolicy/duplicates`` is ``DuplicateHandling/allow``, re-granting an item
    /// stored under another key fails with ``BookmarkStoreError/duplicate(of:)``. The grant is
    /// relinquished whether or not re-granting succeeds.
    @discardableResult
    public func regrant(_ key: Key, with grant: Grant) async throws(Failure) -> Record {
        let context = try await prepare(grant, excluding: key)
        guard let existing = table[key] else {
            service.relinquish(grant)
            throw .notFound(key)
        }
        let resolved = try await adopt(grant, for: key, context: context)
        let location = resolved.handle.path
        if policy.requiresSameItemOnRegrant, !Self.isSameItem(resolved, at: location, as: existing) {
            throw .differentItem(key)
        }
        let path = location.string
        let timestamp = now()
        return try await mutate { [policy, kind] table throws(Failure) in
            if policy.duplicates != .allow,
               let other = table.duplicate(of: resolved.fileIdentity, path: location, excluding: key) {
                throw .duplicate(of: other.key)
            }
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
            return record
        }
    }

    /// Removes the record for `key`. Active leases keep access until they end.
    ///
    /// - Returns: Whether a record was removed.
    @discardableResult
    public func forget(_ key: Key) async throws(Failure) -> Bool {
        try await mutate { table throws(Failure) in
            table.remove(key)
        }
    }

    /// Removes every record. Active leases keep access until they end.
    public func removeAll() async throws(Failure) {
        try await mutate { table throws(Failure) in
            table.removeAll()
        }
    }

    /// Changes the metadata stored for `key`.
    ///
    /// `change` runs on the stored record as it is when the change is saved, which may
    /// include changes made by another process.
    public func updateMetadata(_ key: Key, _ change: @escaping @Sendable (inout Metadata) -> Void) async throws(Failure) {
        try await mutate { table throws(Failure) in
            guard table.updateMetadata(of: key, change) else { throw .notFound(key) }
        }
    }

    /// Moves `key` to `index` in the store's order.
    public func move(_ key: Key, to index: Int) async throws(Failure) {
        try await mutate { table throws(Failure) in
            guard table.move(key, to: index) else { throw .notFound(key) }
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
            guard table.isCurrent(snapshot) else { continue }
            let lease = registry.lease(for: key, resolved: resolved)
            let identity = await identity(of: lease.url)
            guard await commit(resolved, identity: identity, for: snapshot) else {
                lease.end()
                continue
            }
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

    /// A lease that covers `url`, or `nil` when neither an active scope nor a stored item does.
    ///
    /// An active scope anywhere in the process that contains `url` and grants the access this
    /// store's kind grants is reused first, whichever store or resolved bookmark holds it.
    /// Otherwise the deepest stored item that contains `url` and resolves wins; when none
    /// resolves, the deepest one's error is thrown. Use ``AccessLease/url(forDescendant:)`` to
    /// reach `url` through the lease, so files inside a folder share the folder's access.
    public func lease(covering url: URL) async throws(Failure) -> AccessLease? {
        try await load()
        if let access = kind.grantedAccess, let active = service.ledger.lease(covering: url, access: access) {
            return active
        }
        let (_, isCaseSensitive) = await inspect(url, identity: false)
        let candidates = table.keysContaining(NormalizedPath(url, isCaseSensitive: isCaseSensitive))
        var deepestFailure: Failure?
        for key in candidates {
            do {
                return try await lease(key)
            } catch {
                if Task.isCancelled || error.bookmarkFailure == .cancelled { throw error }
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

    /// The keys with at least one active lease.
    public nonisolated var activeKeys: Set<Key> {
        registry.activeKeys
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
    /// Call it when a volume mounts or the app becomes active. Cancelling the calling task
    /// stops it before the next record, throwing ``BookmarkFailure/cancelled``.
    ///
    /// - Returns: The keys that resolved, including ones whose new status failed to save.
    @discardableResult
    public func refreshStatuses() async throws(Failure) -> [Key] {
        try await load()
        let candidates = table.order.compactMap { table.snapshot($0) }.filter { $0.record.status != .available }
        var recovered: [Key] = []
        for snapshot in candidates {
            guard !Task.isCancelled else { throw .bookmark(BookmarkError(.cancelled)) }
            let resolved: ResolvedBookmark
            do {
                resolved = try await resolve(snapshot)
            } catch {
                if error.bookmarkFailure == .cancelled { throw error }
                continue
            }
            if await commit(resolved, identity: nil, for: snapshot) {
                recovered.append(snapshot.key)
            }
        }
        return recovered
    }

    // MARK: - Internals

    func pendingResolutionCallers(for key: Key) -> Int {
        resolutions.filter { $0.key.key == key }.values.reduce(0) { $0 + $1.callers }
    }

    private func adopt(_ grant: Grant, for key: Key, context: ValidationContext) async throws(Failure) -> ResolvedBookmark {
        do {
            return try await service.adopt(grant, kind: kind, validators: policy.validators + validatorsForKey(key), context: context)
        } catch {
            throw .bookmark(error)
        }
    }

    /// Resolves the snapshot's bookmark, sharing one resolution with concurrent callers.
    ///
    /// A failure is recorded once, by the shared resolution, before any caller sees it.
    private func resolve(_ snapshot: Table.Snapshot) async throws(Failure) -> ResolvedBookmark {
        let flight = Flight(key: snapshot.key, generation: snapshot.generation)
        let task = sharedResolution(of: snapshot, flight: flight)
        let result: Result<ResolvedBookmark, BookmarkError>
        do {
            result = try await task.valueUnlessCancelled
        } catch {
            leave(flight, of: task)
            throw .bookmark(BookmarkError(.cancelled))
        }
        leave(flight, of: task)
        return try result.mapError(Failure.bookmark).get()
    }

    /// Stops counting a caller of `task`, unless a later resolution has taken its flight.
    private func leave(_ flight: Flight, of task: Task<Result<ResolvedBookmark, BookmarkError>, Never>) {
        guard var resolution = resolutions[flight], resolution.task == task else { return }
        resolution.callers -= 1
        resolutions[flight] = resolution
    }

    private func sharedResolution(of snapshot: Table.Snapshot, flight: Flight) -> Task<Result<ResolvedBookmark, BookmarkError>, Never> {
        if var resolution = resolutions[flight] {
            resolution.callers += 1
            resolutions[flight] = resolution
            return resolution.task
        }
        let policy = ResolutionPolicy(mounting: policy.mounting, allowsUI: policy.allowsUI)
        let service = service
        let record = snapshot.record
        let task = Task {
            let result: Result<ResolvedBookmark, BookmarkError>
            do throws(BookmarkError) {
                result = .success(try await service.resolve(record.data, kind: record.kind, policy: policy))
            } catch {
                result = .failure(error)
                if error.failure != .cancelled {
                    await commit(error.failure, for: snapshot)
                }
            }
            resolutions[flight] = nil
            return result
        }
        resolutions[flight] = Resolution(task: task, callers: 1)
        return task
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
                table.applySuccess(resolution, to: snapshot) != .superseded
            }
        } catch {
            Log.store.error("Saving a resolved bookmark failed: \(String(describing: error), privacy: .private)")
            return table.isCurrent(snapshot)
        }
    }

    private func commit(_ failure: BookmarkFailure, for snapshot: Table.Snapshot) async {
        let dropping = policy.failureHandling.drops(failure)
        // A record that changed since it was read isn't marked, and one already marked with
        // this failure has nothing to save, so a record that keeps failing costs a resolution
        // but no read or write of the persistence.
        guard table.isCurrent(snapshot), dropping || table[snapshot.key]?.status.failure != failure else { return }
        let timestamp = now()
        do {
            try await mutate { table throws(Failure) in
                table.applyFailure(failure, to: snapshot, dropping: dropping, at: timestamp)
            }
        } catch {
            Log.store.error("Saving a bookmark's status failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Moves `key` to the front of a most-recently-used order. The lease it follows stands
    /// either way, so a failed save only leaves the order as it was.
    private func touch(_ key: Key) async {
        guard policy.ordering == .mostRecentlyUsed, table.order.first != key else { return }
        do {
            try await mutate { [policy] table throws(Failure) in
                table.promote(key, ordering: policy.ordering)
            }
        } catch {
            Log.store.error("Saving the order of recent bookmarks failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func identity(of url: URL) async -> FileIdentity? {
        let engine = service.engine
        return try? await service.executor.run(timeout: service.timeout) { engine.fileIdentity(of: url) }
    }

    /// The item's identity and whether its volume's names differ by case, assuming they do
    /// when the volume doesn't answer.
    private func inspect(_ url: URL, identity: Bool = true) async -> (FileIdentity?, Bool) {
        let engine = service.engine
        let inspection = try? await service.executor.run(timeout: service.timeout) {
            (identity ? engine.fileIdentity(of: url) : nil, engine.namesAreCaseSensitive(at: url))
        }
        return inspection ?? (nil, true)
    }

    private func snapshot(_ key: Key) throws(Failure) -> Table.Snapshot {
        guard let snapshot = table.snapshot(key) else { throw .notFound(key) }
        return snapshot
    }

    /// Loads the records and describes them for validators, relinquishing `grant` on failure.
    private func prepare(_ grant: Grant, excluding key: Key) async throws(Failure) -> ValidationContext {
        do throws(Failure) {
            if kind == .implicit, service.environment.supportsSecurityScope {
                throw .bookmark(BookmarkError(.unsupported(reason: Self.persistedImplicitReason)))
            }
            try await load()
            return ValidationContext(existingPaths: table.paths(excluding: key))
        } catch {
            service.relinquish(grant)
            throw error
        }
    }

    private static var persistedImplicitReason: String {
        "On macOS, implicit bookmarks grant access to any process that resolves them, so stores don't keep them. Use an app-scoped kind."
    }

    /// Whether a re-granted item is the stored one: by file identity when both are known, by
    /// path when only the stored one is, and assumed when the stored record has none.
    private static func isSameItem(_ resolved: ResolvedBookmark, at location: NormalizedPath, as record: Record) -> Bool {
        guard let expected = record.fileIdentity else { return true }
        guard let identity = resolved.fileIdentity else {
            return location.matches(NormalizedPath(record.lastKnownPath, isCaseSensitive: location.isCaseSensitive))
        }
        return identity == expected
    }

    /// Applies `body` to the records as stored now and saves the result.
    ///
    /// The change runs inside ``BookmarkPersistence/update(_:)`` against what the persistence
    /// holds at that moment, so records another process saved since the last read are kept,
    /// and their changes reach subscribers along with this one. Memory changes only after the
    /// save succeeds.
    @discardableResult
    private func mutate<T: Sendable>(
        _ body: @escaping @Sendable (inout Table) throws(Failure) -> T
    ) async throws(Failure) -> T {
        try await load()
        return try await writes.withLock { () async throws(Failure) in
            let base = table
            var (result, draft) = try await applyToStored(base, body)
            let (changes, invalidated) = draft.takeChanges(since: base)
            table = draft
            // Published before the lock is released, so subscribers see changes in the order
            // they were saved.
            finish(changes, invalidating: invalidated)
            return result
        }
    }

    private func applyToStored<T: Sendable>(
        _ base: Table,
        _ body: @escaping @Sendable (inout Table) throws(Failure) -> T
    ) async throws(Failure) -> (T, Table) {
        let persistence = persistence
        let keepsKnownState = !persistence.storesRecordState
        let outcome: Result<(T, Table), Failure>
        do {
            outcome = try await persistenceExecutor.perform { () throws(PersistenceError) -> Result<(T, Table), Failure> in
                var outcome: Result<(T, Table), Failure>?
                try persistence.update { stored in
                    var draft = base
                    draft.replaceAll(with: stored, keepingKnownState: keepsKnownState)
                    // What is stored, as far as this store knows it. Where the persistence
                    // can't hold state, that includes the state kept in memory, so a change
                    // that leaves the records as they were saves nothing.
                    let current = keepsKnownState ? draft.orderedRecords : stored
                    do throws(Failure) {
                        let result = try body(&draft)
                        outcome = .success((result, draft))
                        let records = draft.orderedRecords
                        return records.elementsEqual(current, by: Table.sameRecord) ? nil : records
                    } catch {
                        outcome = .failure(error)
                        return nil
                    }
                }
                guard let outcome else {
                    throw PersistenceError(.writeFailed)
                }
                return outcome
            }
        } catch {
            throw .persistence(error)
        }
        return try outcome.get()
    }

    private nonisolated func finish(_ changes: [StoreChange<Key, Metadata>], invalidating keys: Set<Key>) {
        keys.forEach(registry.detach)
        guard !changes.isEmpty else { return }
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            changes.forEach { continuation.yield(.change($0)) }
        }
    }

    private func loadFromPersistence() async -> Result<[Record], PersistenceError> {
        let persistence = persistence
        do {
            return .success(try await persistenceExecutor.perform { () throws(PersistenceError) in try persistence.load() })
        } catch {
            return .failure(error)
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

    /// Adopts a granted item, stores it under `key` and leases it in one step.
    public func addAndLease(_ grant: Grant, key: Key) async throws(Failure) -> (record: Record, lease: AccessLease) {
        try await addAndLease(grant, key: key, metadata: NoMetadata())
    }
}

extension BookmarkStore where Key == BookmarkID, Metadata == NoMetadata {
    /// Adopts a granted item and stores it under a new identifier.
    @discardableResult
    public func add(_ grant: Grant) async throws(Failure) -> Record {
        try await add(grant, key: BookmarkID(), metadata: NoMetadata())
    }
}
