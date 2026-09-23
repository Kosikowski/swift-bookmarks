import Foundation

/// Records whether a one-time migration has run.
public struct MigrationMarker: Sendable {
    private let isCompleteCheck: @Sendable () -> Bool
    private let markCompleteAction: @Sendable () -> Void

    /// Creates a marker from closures that read and set the completion flag.
    ///
    /// To rely on the clean-up alone, report completion when the legacy data is gone and do
    /// nothing in `markComplete`.
    public init(isComplete: @escaping @Sendable () -> Bool, markComplete: @escaping @Sendable () -> Void) {
        isCompleteCheck = isComplete
        markCompleteAction = markComplete
    }

    /// Keeps the completion flag as a Boolean in `UserDefaults`.
    public static func userDefaults(key: String, suiteName: String? = nil) -> MigrationMarker {
        MigrationMarker(
            isComplete: { defaults(suiteName)?.bool(forKey: key) ?? false },
            markComplete: { defaults(suiteName)?.set(true, forKey: key) }
        )
    }

    /// Whether the migration has run.
    public var isComplete: Bool { isCompleteCheck() }

    /// Records that the migration has run.
    public func markComplete() { markCompleteAction() }

    private static func defaults(_ suiteName: String?) -> UserDefaults? {
        guard let suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName)
    }
}

/// Imports records from a legacy source once, the first time the base persistence is empty.
///
/// The legacy data is cleaned up only after the imported records were saved, so a failed
/// import never loses the original. The marker keeps a store the user later empties from
/// being filled again from legacy data.
public struct MigratingPersistence<Base: BookmarkPersistence>: BookmarkPersistence {
    public typealias Key = Base.Key
    public typealias Metadata = Base.Metadata

    private let base: Base
    private let marker: MigrationMarker
    private let legacy: @Sendable () throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]?
    private let cleanUp: @Sendable () -> Void

    /// Creates a migrating persistence.
    ///
    /// - Parameters:
    ///   - base: Where records live from now on.
    ///   - marker: Records that the migration ran. A failed legacy read leaves it unset.
    ///   - legacy: Reads records from the old location, or returns `nil` when there are none.
    ///   - cleanUp: Removes the old data. Runs once, after the imported records are saved.
    public init(
        base: Base,
        marker: MigrationMarker,
        legacy: @escaping @Sendable () throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]?,
        cleanUp: @escaping @Sendable () -> Void = {}
    ) {
        self.base = base
        self.marker = marker
        self.legacy = legacy
        self.cleanUp = cleanUp
    }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let current = try base.load()
        guard !marker.isComplete else { return current }
        guard current.isEmpty, let imported = try legacy(), !imported.isEmpty else {
            marker.markComplete()
            return current
        }
        try base.save(imported)
        cleanUp()
        marker.markComplete()
        return imported
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        try base.save(records)
    }

    public func update(
        _ transform: ([BookmarkRecord<Key, Metadata>]) -> [BookmarkRecord<Key, Metadata>]?
    ) throws(PersistenceError) {
        if !marker.isComplete {
            _ = try load()
        }
        try base.update(transform)
    }
}
