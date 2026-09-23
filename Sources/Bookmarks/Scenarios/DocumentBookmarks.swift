public import Foundation

/// Creates and resolves document-scoped bookmarks to files referenced from one document.
///
/// Any app that can open the document can resolve these bookmarks, so they suit references
/// stored inside a document the user shares. The system requires both the document and the
/// targets to be files, and the app needs the
/// `com.apple.security.files.bookmarks.document-scope` entitlement. Tools that strip
/// extended attributes from the document break its bookmarks. macOS and Mac Catalyst only.
public struct DocumentBookmarks: Sendable {
    /// The document that anchors the bookmarks.
    public let document: URL
    /// The access the bookmarks grant.
    public let access: AccessMode
    /// The bookmark service.
    public let bookmarks: Bookmarks

    /// Creates a helper for bookmarks anchored on `document`.
    public init(document: URL, access: AccessMode = .readWrite, bookmarks: Bookmarks = Bookmarks()) {
        self.document = document
        self.access = access
        self.bookmarks = bookmarks
    }

    /// The kind of the bookmarks.
    public var kind: BookmarkKind { .documentScoped(access) }

    /// Creates a bookmark to a granted file, anchored on the document.
    ///
    /// The grant is relinquished whether or not creation succeeds. Fails with
    /// ``BookmarkFailure/unsupported(reason:)`` when the document isn't a file, and with
    /// ``BookmarkFailure/refused(_:)`` when the target isn't a file.
    public func create(for grant: Grant) async throws(BookmarkError) -> BookmarkData {
        try await bookmarks.consuming(grant) { () throws(BookmarkError) -> BookmarkData in
            try await checkDocument()
            return try await bookmarks.create(for: grant, kind: kind, relativeTo: document, validators: [.fileOnly])
        }
    }

    /// Resolves a bookmark created by ``create(for:)``, refreshing it when stale.
    public func resolve(_ data: BookmarkData, policy: ResolutionPolicy = .default) async throws(BookmarkError) -> ResolvedBookmark {
        try await bookmarks.resolve(data, kind: kind, relativeTo: document, policy: policy)
    }

    /// Resolves a bookmark, holds access while `body` runs, and ends it afterwards.
    nonisolated(nonsending) public func withAccess<T>(
        to data: BookmarkData,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try await bookmarks.withAccess(to: data, kind: kind, relativeTo: document, body)
    }

    private func checkDocument() async throws(BookmarkError) {
        try bookmarks.checkSupported(kind, document: document)
        let engine = bookmarks.engine
        let document = document
        let info = try await bookmarks.run { () throws(BookmarkError) -> ItemInfo? in engine.itemInfo(at: document) }
        guard let info else {
            throw BookmarkError(.missing, lastKnownPath: document.path(percentEncoded: false))
        }
        if info.isDirectory {
            throw BookmarkError(.unsupported(reason: "Document-scoped bookmarks must be anchored on a file, not a folder."))
        }
    }
}
