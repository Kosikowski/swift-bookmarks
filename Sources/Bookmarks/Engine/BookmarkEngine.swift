public import Foundation

/// The only boundary between the library and the operating system.
///
/// Every call is synchronous and may block, so the library always calls an engine through a
/// ``BlockingExecutor``. Implementations must be safe to call from any thread and must not call
/// back into the library: starts and stops run while the library holds its locks.
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
    func startAccessing(_ url: URL) -> Bool

    /// Balances one successful ``startAccessing(_:)``.
    func stopAccessing(_ url: URL)

    /// Whether an item exists at `path`.
    func itemExists(atPath path: String) -> Bool

    /// The item's path-independent identity, when the volume reports one.
    func fileIdentity(of url: URL) -> FileIdentity?

    /// Describes the item at `url`, or `nil` when it can't be inspected.
    func itemInfo(at url: URL) -> ItemInfo?

    /// Writes alias-file bookmark bytes to `url`.
    func writeAliasFile(_ data: BookmarkData, to url: URL) throws

    /// Reads the bookmark bytes stored in the alias file at `url`.
    func aliasFileData(at url: URL) throws -> BookmarkData
}
