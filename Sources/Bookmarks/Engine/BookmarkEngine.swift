public import Foundation

/// Creates and resolves bookmark bytes and starts and stops security-scoped access.
///
/// Engines are the only boundary between the library and the operating system. Calls that
/// create, resolve or inspect bookmarks may block, so the library makes them through a
/// ``BlockingExecutor``. ``startAccessing(_:)`` and ``stopAccessing(_:)`` are different: they run
/// synchronously on whichever thread begins or ends a lease, including actors and the main
/// thread, while the library holds its locks. They must return quickly and must not call back
/// into the library. Every method must be safe to call from any thread.
/// ``SystemBookmarkEngine`` is the real implementation; `BookmarksTesting` provides a fake.
public protocol BookmarkEngine: Sendable {
    /// The environment the engine operates in.
    var environment: SandboxEnvironment { get }

    /// Creates bookmark bytes for `url`.
    func makeBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        includingResourceValuesFor keys: Set<URLResourceKey>,
        relativeTo document: URL?
    ) throws -> BookmarkData

    /// Resolves bookmark bytes to a URL and reports whether they are stale.
    func resolve(
        _ data: BookmarkData,
        options: URL.BookmarkResolutionOptions,
        relativeTo document: URL?
    ) throws -> (url: URL, isStale: Bool)

    /// Reads what the bookmark recorded about its target, without resolving it.
    func recordedValues(in data: BookmarkData) -> RecordedValues?

    /// Starts security-scoped access to `url`. Returns whether there is now access to balance.
    ///
    /// Called synchronously on the caller's thread while the library holds its locks.
    func startAccessing(_ url: URL) -> Bool

    /// Balances one successful ``startAccessing(_:)``.
    ///
    /// Called synchronously on the caller's thread while the library holds its locks.
    func stopAccessing(_ url: URL)
}

/// Inspects items on disk, for validation, failure classification and duplicate detection.
public protocol ItemInspecting: Sendable {
    /// Whether a volume is mounted at `path`.
    ///
    /// A folder left where a volume used to be mounted, such as an empty `/Volumes/Backup`
    /// after an unclean unmount, isn't a mounted volume.
    func isVolumeMounted(atPath path: String) -> Bool

    /// The item's path-independent identity, or `nil` when the volume doesn't report both a
    /// file identifier and a volume UUID.
    func fileIdentity(of url: URL) -> FileIdentity?

    /// Describes the item at `url`, or `nil` when it can't be inspected.
    func itemInfo(at url: URL) -> ItemInfo?

    /// Whether names on the volume that holds `url` differ by case.
    ///
    /// When nothing exists at `url`, its nearest existing ancestor decides. Return `true` when
    /// unsure: comparing paths case-sensitively on a volume that ignores case only costs extra
    /// system starts, while the opposite could map a path onto a different item.
    func namesAreCaseSensitive(at url: URL) -> Bool
}

/// Reads and writes Finder alias files.
public protocol AliasFileAccessing: Sendable {
    /// Writes alias-file bookmark bytes to `url`.
    func writeAliasFile(_ data: BookmarkData, to url: URL) throws

    /// Reads the bookmark bytes stored in the alias file at `url`.
    func aliasFileData(at url: URL) throws -> BookmarkData
}

/// Everything ``BookmarkService`` needs from the system.
public typealias FileSystemEngine = BookmarkEngine & ItemInspecting & AliasFileAccessing
