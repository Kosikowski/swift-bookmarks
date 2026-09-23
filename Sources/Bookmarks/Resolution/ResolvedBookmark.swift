public import Foundation

/// A bookmark that resolved successfully.
///
/// It deliberately exposes no file URL: file access goes through ``beginAccess()``, so the
/// scope always travels with the URL instance that the system resolved.
public final class ResolvedBookmark: Sendable {
    /// The kind the bookmark was resolved as.
    public let kind: BookmarkKind
    /// The bytes that were resolved.
    public let originalData: BookmarkData
    /// Whether the system reported the bytes as stale.
    public let wasStale: Bool
    /// Fresh bytes created because the original ones were stale. Persist them in place of
    /// ``originalData``.
    public let refreshedData: BookmarkData?
    /// Why refreshing stale bytes failed. Access still works; keep ``originalData``.
    public let refreshError: BookmarkError?
    /// What the bookmark recorded about its target.
    public let recorded: RecordedValues?
    /// The item's identity, when it was determined while access was held.
    public let fileIdentity: FileIdentity?
    /// The resolved path, for display and comparison only.
    public let displayPath: String

    let handle: ScopeHandle

    init(
        kind: BookmarkKind,
        originalData: BookmarkData,
        wasStale: Bool,
        refreshedData: BookmarkData?,
        refreshError: BookmarkError?,
        recorded: RecordedValues?,
        fileIdentity: FileIdentity?,
        handle: ScopeHandle
    ) {
        self.kind = kind
        self.originalData = originalData
        self.wasStale = wasStale
        self.refreshedData = refreshedData
        self.refreshError = refreshError
        self.recorded = recorded
        self.fileIdentity = fileIdentity
        self.handle = handle
        displayPath = handle.url.path(percentEncoded: false)
    }

    /// The bytes to keep: refreshed ones when available, otherwise the original ones.
    public var data: BookmarkData { refreshedData ?? originalData }

    /// Whether the caller should persist ``data`` because it differs from what it stored.
    public var needsPersisting: Bool { refreshedData != nil }

    /// Starts access to the resolved item. End the lease when done.
    ///
    /// Leases from the same `ResolvedBookmark` share one system start.
    public func beginAccess() -> AccessLease {
        AccessLease(handle: handle)
    }

    /// The resolved URL for callers that need it without access, such as display or
    /// non-sandboxed builds. Prefer ``beginAccess()`` for file operations.
    public var unscopedURL: URL { handle.url }
}
