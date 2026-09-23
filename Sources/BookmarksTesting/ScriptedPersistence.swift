public import Bookmarks
import Synchronization

/// Keeps records in memory and fails loads or saves on request, for testing how an app
/// handles storage errors.
public final class ScriptedPersistence<Key: Hashable & Sendable, Metadata: Sendable>: BookmarkPersistence {
    private struct State {
        var records: [BookmarkRecord<Key, Metadata>]
        var failingLoads: (count: Int, reason: PersistenceError.Reason) = (0, .readFailed)
        var failingSaves: (count: Int, reason: PersistenceError.Reason) = (0, .writeFailed)
        var loadCount = 0
        var updateCount = 0
        var saveCount = 0
    }

    private let state: Mutex<State>

    /// Creates a persistence holding `records`.
    public init(records: [BookmarkRecord<Key, Metadata>] = []) {
        state = Mutex(State(records: records))
    }

    /// Makes the next `count` loads fail with `reason`. Updates still succeed; script them with
    /// ``failSaves(_:reason:)``.
    public func failLoads(_ count: Int, reason: PersistenceError.Reason = .readFailed) {
        state.withLock { $0.failingLoads = (count, reason) }
    }

    /// Makes the next `count` saves fail with `reason`. Failed saves keep the stored records.
    public func failSaves(_ count: Int, reason: PersistenceError.Reason = .writeFailed) {
        state.withLock { $0.failingSaves = (count, reason) }
    }

    /// Replaces the stored records without a save, as another process writing them would.
    public func replaceStoredRecords(_ records: [BookmarkRecord<Key, Metadata>]) {
        state.withLock { $0.records = records }
    }

    /// The records as last saved or replaced.
    public var storedRecords: [BookmarkRecord<Key, Metadata>] {
        state.withLock { $0.records }
    }

    /// How many times ``load()`` was called, including failed loads.
    public var loadCount: Int {
        state.withLock { $0.loadCount }
    }

    /// How many times ``save(_:)`` or ``update(_:)`` was called, including ones that saved
    /// nothing or failed.
    public var updateCount: Int {
        state.withLock { $0.updateCount }
    }

    /// How many times ``save(_:)`` or ``update(_:)`` saved records.
    public var saveCount: Int {
        state.withLock { $0.saveCount }
    }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let outcome = state.withLock { state -> Result<[BookmarkRecord<Key, Metadata>], PersistenceError> in
            state.loadCount += 1
            guard state.failingLoads.count > 0 else { return .success(state.records) }
            state.failingLoads.count -= 1
            return .failure(PersistenceError(state.failingLoads.reason))
        }
        return try outcome.get()
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        try update { _ in records }
    }

    /// Applies `transform` to the stored records as one step, like a backend shared between
    /// processes. A scripted save failure fails the update and keeps the stored records.
    public func update(
        _ transform: ([BookmarkRecord<Key, Metadata>]) -> [BookmarkRecord<Key, Metadata>]?
    ) throws(PersistenceError) {
        let failure = state.withLock { state -> PersistenceError? in
            state.updateCount += 1
            guard let records = transform(state.records) else { return nil }
            guard state.failingSaves.count > 0 else {
                state.records = records
                state.saveCount += 1
                return nil
            }
            state.failingSaves.count -= 1
            return PersistenceError(state.failingSaves.reason)
        }
        if let failure { throw failure }
    }
}
