public import Foundation

/// Creates and resolves document-scoped bookmarks to files referenced from one document.
///
/// Any app that can open the document can resolve these bookmarks, so they suit references
/// stored inside a document the user shares. The system requires both the document and the
/// targets to be files, and the app needs the
/// `com.apple.security.files.bookmarks.document-scope` entitlement; without it, creation
/// fails with ``BookmarkFailure/denied``. Tools that strip extended attributes from the
/// document break its bookmarks. macOS and Mac Catalyst only.
public struct DocumentBookmarks: Sendable {
    /// The document that anchors the bookmarks.
    public let document: URL
    /// The access the bookmarks grant.
    public let access: AccessMode
    /// The bookmark service.
    public let service: BookmarkService

    init(document: URL, access: AccessMode, service: BookmarkService) {
        self.document = document
        self.access = access
        self.service = service
    }

    /// The kind of the bookmarks.
    public var kind: BookmarkKind { .documentScoped(access) }

    /// Creates a bookmark to a granted file, anchored on the document.
    ///
    /// The grant is relinquished whether or not creation succeeds. Fails with
    /// ``BookmarkFailure/unsupported(reason:)`` when the document isn't a file, and with
    /// ``BookmarkFailure/refused(_:)`` when the target isn't a file.
    public func create(for grant: Grant) async throws(BookmarkError) -> BookmarkData {
        try await service.consuming(grant) { () throws(BookmarkError) -> BookmarkData in
            try await checkDocument()
            return try await service.create(
                for: grant,
                kind: kind,
                document: document,
                keys: [],
                validation: BookmarkService.Validation(validators: [.fileOnly], context: ValidationContext())
            )
        }
    }

    /// Resolves a bookmark created by ``create(for:)``, refreshing it when stale.
    public func resolve(_ data: BookmarkData, policy: ResolutionPolicy = .default) async throws(BookmarkError) -> ResolvedBookmark {
        try await service.resolve(data, kind: kind, document: document, policy: policy)
    }

    /// Checks whether a bookmark's target is reachable, without mounting volumes, showing UI
    /// or starting access.
    public func availability(of data: BookmarkData) async -> Availability {
        await service.availability(of: data, kind: kind, document: document)
    }

    /// Resolves a bookmark, holds access while `body` runs, and ends it afterwards.
    nonisolated(nonsending) public func withAccess<T>(
        to data: BookmarkData,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try await service.withAccess(to: data, kind: kind, document: document, policy: .default, body)
    }

    private func checkDocument() async throws(BookmarkError) {
        try service.checkSupported(kind, document: document)
        let engine = service.engine
        let document = document
        let info = try await service.run { () throws(BookmarkError) -> ItemInfo? in engine.itemInfo(at: document) }
        guard let info else {
            throw BookmarkError(.missing, lastKnownPath: document.path(percentEncoded: false))
        }
        if info.isDirectory {
            throw BookmarkError(.unsupported(reason: "Document-scoped bookmarks must be anchored on a file, not a folder."))
        }
    }
}
