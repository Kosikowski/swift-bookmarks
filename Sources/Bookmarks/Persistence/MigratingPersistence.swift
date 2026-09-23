import Foundation

/// Records whether a one-time migration has run.
public struct MigrationMarker: Sendable {
    private let isCompleteCheck: @Sendable () -> Bool
    private let markCompleteAction: @Sendable () -> Void

    /// Creates a marker from closures that read and set the completion flag.
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

    /// Keeps no flag and relies on the clean-up removing the legacy data.
    public static let cleanUpOnly = MigrationMarker(isComplete: { false }, markComplete: {})

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
/// import never loses the original. Pass a ``MigrationMarker`` that persists completion so a
/// store the user later empties isn't filled again from legacy data that wasn't removed.
public struct MigratingPersistence<Base: BookmarkPersistence>: BookmarkPersistence {
    public typealias Key = Base.Key
    public typealias Metadata = Base.Metadata

    private let base: Base
    private let legacy: @Sendable () throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]?
    private let cleanUp: @Sendable () -> Void
    private let marker: MigrationMarker

    /// Creates a migrating persistence.
    ///
    /// - Parameters:
    ///   - base: Where records live from now on.
    ///   - legacy: Reads records from the old location, or returns `nil` when there are none.
    ///   - cleanUp: Removes the old data. Runs once, after the imported records are saved.
    ///   - marker: Records that the migration ran. A failed legacy read leaves it unset.
    public init(
        base: Base,
        legacy: @escaping @Sendable () throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>]?,
        cleanUp: @escaping @Sendable () -> Void = {},
        marker: MigrationMarker = .cleanUpOnly
    ) {
        self.base = base
        self.legacy = legacy
        self.cleanUp = cleanUp
        self.marker = marker
    }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let current = try base.load()
        guard !marker.isComplete else { return current }
        guard current.isEmpty else {
            marker.markComplete()
            return current
        }
        guard let imported = try legacy(), !imported.isEmpty else {
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
}
