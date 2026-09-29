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
///
/// ``snapshot`` gives the records synchronously, for code that can't wait. Records without a
/// bookmark, added with ``add(pathOnly:key:metadata:)``, are found by path and get a bookmark
/// as soon as one can be made. With a ``StorePolicy/limit``, the policy's
/// ``StorePolicy/eviction`` decides which records go, and ``evictions(bufferingPolicy:)``
/// reports them.
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
    private let evictionObservers = Mutex<[UUID: AsyncStream<StoreEviction<Key, Metadata>>.Continuation]>([:])
    private let published = Mutex(StoreSnapshot<Key, Metadata>(isLoaded: false))
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
        evictionObservers.withLock { $0.values.forEach { $0.finish() } }
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
            publishSnapshot()
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
            publish(table.takeChanges(since: old))
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

    /// The records as of the last change this store saved or loaded, readable synchronously
    /// from any thread.
    ///
    /// It's empty, with ``StoreSnapshot/isLoaded`` `false`, until the records load; call
    /// ``load()`` at launch. It changes before ``updates(bufferingPolicy:)`` reports the change,
    /// so a subscriber that reads it on an update sees at least that change.
    public nonisolated var snapshot: StoreSnapshot<Key, Metadata> {
        published.withLock { $0 }
    }

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

    /// Every record the store removes on its own from now on: records evicted beyond
    /// ``StorePolicy/limit``, and records ``StorePolicy/failureHandling`` drops when they fail
    /// to resolve.
    ///
    /// Apps that keep their own data under the store's keys clear it here. Call it before
    /// adding records, such as right after creating the store; each call returns a new
    /// stream. Records removed with ``forget(_:)`` aren't reported, and records another process
    /// removed arrive only as ``StoreChange/removed(_:)`` updates.
    public nonisolated func evictions(
        bufferingPolicy: AsyncStream<StoreEviction<Key, Metadata>>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<StoreEviction<Key, Metadata>> {
        let (stream, continuation) = AsyncStream<StoreEviction<Key, Metadata>>.makeStream(bufferingPolicy: bufferingPolicy)
        let id = UUID()
        evictionObservers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.evictionObservers.withLock { _ = $0.removeValue(forKey: id) }
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
            Item(
                data: resolved.data,
                kind: kind,
                location: resolved.handle.path,
                identity: resolved.fileIdentity,
                status: .available,
                lastUsedAt: now()
            ),
            key: key,
            metadata: metadata
        )
        return (record, resolved)
    }

    /// Stores `url` without a bookmark under `key`, replacing any record for `key`.
    ///
    /// Use it for an item the app knows only by its path, or when making a bookmark failed.
    /// The record's ``BookmarkRecord/data`` is `nil`, and the store finds the item by
    /// ``BookmarkRecord/lastKnownPath`` alone, so it doesn't follow moves. Leasing the record
    /// or refreshing statuses makes a bookmark of the record's kind, the store's kind when it
    /// was added, as soon as the app can reach the item, such as while it holds access to a
    /// folder that contains it; to make one from a grant, call ``regrant(_:with:)``. Until then,
    /// leasing fails as making the bookmark did, such as with ``BookmarkFailure/denied`` inside
    /// the App Sandbox.
    ///
    /// Duplicates are handled as by ``add(_:key:metadata:)``, by identity when the item can be
    /// inspected and by path otherwise. Validators don't run, because the item isn't accessed.
    @discardableResult
    public func add(pathOnly url: URL, key: Key, metadata: Metadata) async throws(Failure) -> Record {
        try checkPersistableKind()
        try await load()
        let url = url.standardizedFileURL
        let (identity, isCaseSensitive) = await inspect(url)
        return try await insert(
            Item(
                data: nil,
                kind: kind,
                location: NormalizedPath(url, isCaseSensitive: isCaseSensitive),
                identity: identity,
                status: .unknown,
                lastUsedAt: now()
            ),
            key: key,
            metadata: metadata
        )
    }

    /// Stores a bookmark another store keeps, such as when an item moves from one list to
    /// another, under `key`, replacing any record for `key`.
    ///
    /// The bytes, kind, identity and status are taken as they are, and nothing is resolved,
    /// so an item that can't be reached now moves too. Validators don't run, because the item
    /// isn't accessed. Duplicates are handled as by ``add(_:key:metadata:)``; with
    /// ``DuplicateHandling/returnExisting`` the existing record takes the copied bytes and
    /// status. A pinned record stays pinned, and a copy never unpins a record it replaces or
    /// merges into. A path-only record gets its bookmark in this store's kind.
    @discardableResult
    public func add<OtherKey, OtherMetadata>(
        copyOf other: BookmarkRecord<OtherKey, OtherMetadata>,
        key: Key,
        metadata: Metadata
    ) async throws(Failure) -> Record {
        let copiedKind = other.hasBookmark ? other.kind : kind
        if copiedKind == .implicit, service.environment.supportsSecurityScope {
            throw .bookmark(BookmarkError(.unsupported(reason: Self.persistedImplicitReason)))
        }
        try await load()
        let (_, isCaseSensitive) = await inspect(URL(filePath: other.lastKnownPath), identity: false)
        return try await insert(
            Item(
                data: other.data,
                kind: copiedKind,
                location: NormalizedPath(other.lastKnownPath, isCaseSensitive: isCaseSensitive),
                identity: other.fileIdentity,
                status: other.status,
                lastUsedAt: other.lastUsedAt,
                isPinned: other.isPinned
            ),
            key: key,
            metadata: metadata
        )
    }

    private struct Item: Sendable {
        let data: BookmarkData?
        let kind: BookmarkKind
        let location: NormalizedPath
        let identity: FileIdentity?
        let status: RecordStatus
        let lastUsedAt: Date?
        var isPinned = false
    }

    private func insert(_ item: Item, key: Key, metadata: Metadata) async throws(Failure) -> Record {
        let path = item.location.string
        let timestamp = now()
        return try await mutate { [policy] table throws(Failure) in
            if policy.duplicates != .allow,
               let existing = table.duplicate(of: item.identity, path: item.location, excluding: key) {
                guard policy.duplicates == .returnExisting else { throw .duplicate(of: existing.key) }
                if item.isPinned {
                    _ = table.setPinned(existing.key, true)
                }
                // A path says nothing new about an item the store holds a bookmark for.
                if item.data == nil, existing.hasBookmark {
                    _ = table.markUsed(existing.key, at: item.lastUsedAt ?? timestamp, ordering: policy.ordering)
                    return table[existing.key] ?? existing
                }
                return table.replaceItem(
                    of: existing.key,
                    data: item.data,
                    kind: item.kind,
                    path: path,
                    identity: item.identity,
                    status: item.status,
                    date: timestamp,
                    usedAt: item.lastUsedAt,
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
                lastUsedAt: item.lastUsedAt,
                isPinned: item.isPinned || previous?.isPinned == true,
                metadata: metadata
            )
            table.put(record, ordering: policy.ordering)
            table.evict(beyond: policy.limit, keeping: key, ordering: policy.ordering, policy: policy.eviction)
            return record
        }
    }

    /// Replaces the bookmark for `key` with a newly granted item, keeping the key and metadata.
    ///
    /// This also gives a path-only record its bookmark.
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
                usedAt: timestamp,
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

    /// Removes every record `predicate` matches, in one save. Active leases keep access until
    /// they end.
    ///
    /// ```swift
    /// let gone = try await store.forget { $0.isGone }
    /// ```
    ///
    /// `predicate` runs on the records as they are when the change is saved, which may
    /// include changes made by another process.
    ///
    /// - Returns: The removed keys, in the store's order.
    @discardableResult
    public func forget(where predicate: @escaping @Sendable (Record) -> Bool) async throws(Failure) -> [Key] {
        try await mutate { table throws(Failure) in
            table.removeAll(where: predicate)
        }
    }

    /// Removes every record. Active leases keep access until they end.
    public func removeAll() async throws(Failure) {
        try await mutate { table throws(Failure) in
            table.removeAll()
        }
    }

    /// Sets where the item stored under `key` is, such as after the app saved it under a new
    /// name or learned its path some other way.
    ///
    /// For a record with a bookmark it's a hint for display and re-grant prompts until the
    /// bookmark next resolves, which sets it to where the item really is. For a path-only
    /// record it's where the store looks for the item from now on: its identity is read
    /// again and its status becomes ``RecordStatus/unknown``. Unless ``StorePolicy/duplicates``
    /// is ``DuplicateHandling/allow``, pointing a path-only record at an item stored under
    /// another key fails with ``BookmarkStoreError/duplicate(of:)``, as re-granting does.
    @discardableResult
    public func updateLastKnownPath(_ key: Key, to url: URL) async throws(Failure) -> Record {
        try await load()
        let url = url.standardizedFileURL
        let (identity, isCaseSensitive) = await inspect(url)
        let location = NormalizedPath(url, isCaseSensitive: isCaseSensitive)
        let path = location.string
        return try await mutate { [policy] table throws(Failure) in
            if policy.duplicates != .allow, table[key]?.hasBookmark == false,
               let other = table.duplicate(of: identity, path: location, excluding: key) {
                throw .duplicate(of: other.key)
            }
            guard let record = table.setLastKnownPath(key, to: path, identity: identity) else { throw .notFound(key) }
            return record
        }
    }

    /// Records that the item stored under `key` was used now, such as when the app opened it
    /// without a lease, and moves it to the front of a most-recently-used order.
    public func markUsed(_ key: Key) async throws(Failure) {
        let date = now()
        try await mutate { [policy] table throws(Failure) in
            guard table.markUsed(key, at: date, ordering: policy.ordering) else { throw .notFound(key) }
        }
    }

    /// Pins or unpins the record for `key`. Eviction keeps a pinned record while its item isn't
    /// gone; see ``EvictionPolicy``.
    public func setPinned(_ isPinned: Bool, for key: Key) async throws(Failure) {
        try await mutate { table throws(Failure) in
            guard table.setPinned(key, isPinned) else { throw .notFound(key) }
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
    /// again. A path-only record gets a bookmark first, which fails unless the app can reach
    /// the item; see ``add(pathOnly:key:metadata:)``.
    public func lease(_ key: Key) async throws(Failure) -> AccessLease {
        try await load()
        if let lease = registry.activeLease(for: key) {
            // The use began with the access this lease joins, so only the order may change.
            await touch(key, recordingUse: false)
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
    ///
    /// For a path-only record, checks whether an item exists at its last known path. A path
    /// that can't be inspected reads as ``Availability/unknown``, and so does one where nothing
    /// is found inside the App Sandbox, since it may be missing or merely out of reach.
    public func availability(_ key: Key) async throws(Failure) -> Availability {
        try await load()
        guard let record = table[key] else { throw .notFound(key) }
        guard let data = record.data else { return await availability(ofPath: record.lastKnownPath) }
        return await service.availability(of: data, kind: record.kind, document: nil, identity: record.fileIdentity)
    }

    /// Resolves records that aren't known to be available, or every record, and updates their
    /// status and last known path.
    ///
    /// Call it when a volume mounts or the app becomes active, and with `includingAvailable`
    /// before relying on statuses, such as before evicting gone items: a record stays
    /// ``RecordStatus/available`` after its item is deleted until it's resolved again.
    /// Path-only records get a bookmark when one can be made. Cancelling the calling task stops
    /// it before the next record, throwing ``BookmarkFailure/cancelled``.
    ///
    /// - Returns: The keys that resolved, including ones whose new status failed to save.
    @discardableResult
    public func refreshStatuses(includingAvailable: Bool = false) async throws(Failure) -> [Key] {
        try await load()
        let candidates = table.order.compactMap { table.snapshot($0) }.filter { includingAvailable || $0.record.status != .available }
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
                if let data = record.data {
                    result = .success(try await service.resolve(
                        data,
                        kind: record.kind,
                        document: nil,
                        identity: record.fileIdentity,
                        policy: policy
                    ))
                } else if record.kind == .implicit, service.environment.supportsSecurityScope {
                    // Such a record can only have been stored elsewhere, since stores don't make one.
                    throw BookmarkError(.unsupported(reason: Self.persistedImplicitReason))
                } else {
                    result = .success(try await service.bookmark(pathOnly: record.lastKnownPath, kind: record.kind))
                }
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
            identity: identity ?? resolved.fileIdentity,
            date: now(),
            madeKind: snapshot.record.hasBookmark ? nil : resolved.kind
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

    /// Moves `key` to the front of a most-recently-used order and, when `recordingUse` and the
    /// policy asks, records its use. The lease it follows stands either way, so a failed save
    /// only leaves the record as it was.
    private func touch(_ key: Key, recordingUse: Bool = true) async {
        let recordsUse = recordingUse && policy.recordsLastUse
        guard recordsUse || (policy.ordering == .mostRecentlyUsed && table.order.first != key) else { return }
        let date = now()
        do {
            try await mutate { [policy] table throws(Failure) in
                if recordsUse {
                    _ = table.markUsed(key, at: date, ordering: policy.ordering)
                } else {
                    table.promote(key, ordering: policy.ordering)
                }
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
            try checkPersistableKind()
            try await load()
            return ValidationContext(existingPaths: table.paths(excluding: key))
        } catch {
            service.relinquish(grant)
            throw error
        }
    }

    private func checkPersistableKind() throws(Failure) {
        if kind == .implicit, service.environment.supportsSecurityScope {
            throw .bookmark(BookmarkError(.unsupported(reason: Self.persistedImplicitReason)))
        }
    }

    /// Whether an item exists at `path`, for a record that has no bookmark to resolve.
    private func availability(ofPath path: String) async -> Availability {
        let engine = service.engine
        let classifier = service.classifier
        let isSandboxed = service.environment.isSandboxed
        let availability = try? await service.executor.run(timeout: service.timeout) { () -> Availability in
            switch engine.itemExists(atPath: path) {
            case true?: return .available
            // An item that can't be inspected, such as one behind privacy settings, may exist.
            case nil: return .unknown
            case false?: break
            }
            let failure = classifier.classify(CocoaError(.fileNoSuchFile), recorded: RecordedValues(locating: path))
            if case .volumeUnavailable = failure {
                return Availability(failure)
            }
            return isSandboxed ? .unknown : Availability(failure)
        }
        return availability ?? .unknown
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
            let changes = draft.takeChanges(since: base)
            table = draft
            // Published before the lock is released, so subscribers see changes in the order
            // they were saved.
            publish(changes)
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

    /// Publishes the table as it is now: the snapshot first, then the changes and evictions.
    private func publish(_ changes: Table.Changes) {
        changes.invalidated.forEach(registry.detach)
        guard !changes.changes.isEmpty || !changes.evictions.isEmpty else { return }
        publishSnapshot()
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            changes.changes.forEach { continuation.yield(.change($0)) }
        }
        guard !changes.evictions.isEmpty else { return }
        let evictionContinuations = evictionObservers.withLock { Array($0.values) }
        for continuation in evictionContinuations {
            changes.evictions.forEach { continuation.yield($0) }
        }
    }

    private func publishSnapshot() {
        let snapshot = StoreSnapshot(records: table.orderedRecords, isLoaded: true)
        published.withLock { $0 = snapshot }
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

    /// Stores `url` without a bookmark under a new identifier. See ``add(pathOnly:key:metadata:)``.
    @discardableResult
    public func add(pathOnly url: URL, metadata: Metadata) async throws(Failure) -> Record {
        try await add(pathOnly: url, key: BookmarkID(), metadata: metadata)
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

    /// Stores `url` without a bookmark under `key`. See ``add(pathOnly:key:metadata:)``.
    @discardableResult
    public func add(pathOnly url: URL, key: Key) async throws(Failure) -> Record {
        try await add(pathOnly: url, key: key, metadata: NoMetadata())
    }
}

extension BookmarkStore where Key == BookmarkID, Metadata == NoMetadata {
    /// Adopts a granted item and stores it under a new identifier.
    @discardableResult
    public func add(_ grant: Grant) async throws(Failure) -> Record {
        try await add(grant, key: BookmarkID(), metadata: NoMetadata())
    }

    /// Stores `url` without a bookmark under a new identifier. See ``add(pathOnly:key:metadata:)``.
    @discardableResult
    public func add(pathOnly url: URL) async throws(Failure) -> Record {
        try await add(pathOnly: url, key: BookmarkID(), metadata: NoMetadata())
    }
}

extension BookmarkService {
    /// Makes a bookmark of `kind` for the item at `path`, which the app must reach already,
    /// and resolves it: the step that gives a path-only record its bookmark.
    ///
    /// A missing item on a volume that isn't mounted fails with
    /// ``BookmarkFailure/volumeUnavailable(name:)``.
    func bookmark(pathOnly path: String, kind: BookmarkKind) async throws(BookmarkError) -> ResolvedBookmark {
        // The system started nothing for an item the app already reaches, so there's no start
        // for the grant to balance.
        let grant = Grant(url: URL(filePath: path), origin: .alreadyAccessible, platform: environment.platform) { _ in }
        do {
            return try await adopt(grant, kind: kind)
        } catch where error.failure == .missing {
            let classifier = classifier
            let failure = try await run { () throws(BookmarkError) -> BookmarkFailure in
                classifier.classify(CocoaError(.fileNoSuchFile), recorded: RecordedValues(locating: path))
            }
            throw BookmarkError(failure, lastKnownPath: path, underlying: error.underlying)
        }
    }
}

extension RecordedValues {
    /// What a bookmark to `path` would record about the item's volume: one mounted under
    /// `/Volumes`, or the boot volume.
    init(locating path: String) {
        let components = NormalizedPath(path).components
        let volume = components.count >= 2 && components[0] == "Volumes" ? components[1] : nil
        self.init(
            path: path,
            name: components.last,
            volumePath: volume.map { "/Volumes/\($0)" },
            volumeName: volume
        )
    }
}
