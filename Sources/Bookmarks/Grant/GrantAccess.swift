public import Foundation

extension BookmarkService {
    /// Starts access to a granted item for one use, without creating a bookmark.
    ///
    /// Use it for work that ends while the app runs, such as writing a file into a folder the
    /// user just picked. The lease takes over the access the system started for the grant, or
    /// starts access when the grant's origin doesn't, and ending it balances either; a grant
    /// the app already reaches, ``Grant/Origin/alreadyAccessible``, starts nothing. The grant is
    /// used up, as adopting it would use it, so adopt it instead to reach the item again later.
    ///
    /// Leases from ``ScopeLedger/lease(covering:access:)`` and ``BookmarkStore/lease(covering:)``
    /// join this access while it lasts, as they join any active scope.
    ///
    /// Fails with ``BookmarkFailure/unsupported(reason:)`` when the grant was already adopted,
    /// relinquished or used, or is being adopted.
    public func beginAccess(to grant: Grant) throws(BookmarkError) -> AccessLease {
        guard grant.takeOver() else { throw Self.grantUnavailable }
        let handle = ScopeHandle(
            url: grant.url,
            engine: engine,
            ledger: ledger,
            access: .readWrite,
            alreadyStarted: grant.isStartedBySystem,
            startsAccess: grant.origin != .alreadyAccessible
        )
        return AccessLease(handle: handle)
    }

    /// Holds access to a granted item while `body` runs, without creating a bookmark, and
    /// ends it afterwards.
    ///
    /// ```swift
    /// try await service.withAccess(to: grant) { folder in
    ///     try package.write(to: folder.appending(path: "Project.braceform"))
    /// }
    /// ```
    ///
    /// The grant is used up whether or not `body` succeeds. See ``beginAccess(to:)``.
    nonisolated(nonsending) public func withAccess<T>(
        to grant: Grant,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let lease = try beginAccess(to: grant)
        defer { lease.end() }
        return try await body(lease.url)
    }
}
