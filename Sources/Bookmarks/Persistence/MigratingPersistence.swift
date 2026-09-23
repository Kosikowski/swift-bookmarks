/// Imports records from a legacy source the first time the base persistence is empty.
///
/// The legacy data is cleaned up only after the imported records were saved, so a failed
/// import never loses the original.
public struct MigratingPersistence<Base: BookmarkPersistence>: BookmarkPersistence {
    public typealias Key = Base.Key
    public typealias Metadata = Base.Metadata

    private let base: Base
    private let legacy: @Sendable () throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]?
    private let cleanUp: @Sendable () -> Void

    /// Creates a migrating persistence.
    ///
    /// - Parameters:
    ///   - base: Where records live from now on.
    ///   - legacy: Reads records from the old location, or returns `nil` when there are none.
    ///   - cleanUp: Removes the old data. Runs once, after the imported records are saved.
    public init(
        base: Base,
        legacy: @escaping @Sendable () throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]?,
        cleanUp: @escaping @Sendable () -> Void = {}
    ) {
        self.base = base
        self.legacy = legacy
        self.cleanUp = cleanUp
    }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let current = try base.load()
        guard current.isEmpty, let imported = try legacy(), !imported.isEmpty else {
            return current
        }
        try base.save(imported)
        cleanUp()
        return imported
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        try base.save(records)
    }
}
