public import Foundation

/// Creates and resolves document-scoped bookmarks to files referenced from one document.
///
/// Any app that can open the document can resolve these bookmarks, so they suit references
/// stored inside a document the user shares. The system requires both the document and the
/// targets to be files, and the app needs the
/// `com.apple.security.files.bookmarks.document-scope` entitlement; without it, creation
/// fails with ``BookmarkFailure/denied``. Targets in the app's container or temporary folder
/// are refused with ``BookmarkFailure/denied`` too. macOS and Mac Catalyst only.
///
/// The bookmarks depend on a key the system keeps in an extended attribute of the document,
/// which the app can't read or copy. Anything that writes the document as a new file without
/// its extended attributes loses the key, and every bookmark in it then fails with
/// ``BookmarkFailure/denied``: a plain atomic write such as `Data.write(to:options: .atomic)`
/// or `String.write(to:atomically: true)`, and tools that strip extended attributes.
/// Bookmarks made after that get a new key, and the older ones fail with
/// ``BookmarkFailure/needsRegrant``. Writing in place, moving or copying the document, and
/// `FileManager.replaceItemAt(_:withItemAt:)`, which `NSDocument`'s safe saving uses, keep
/// the key. Save the document with ``replaceDocument(_:)`` to replace it atomically and keep
/// its bookmarks working.
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
        try await service.using(grant, consuming: true) { use throws(BookmarkError) -> BookmarkData in
            try await checkDocument()
            return try await service.createClaimed(
                using: use,
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

    /// Replaces the document atomically with a file that `write` writes, keeping the key its
    /// bookmarks depend on.
    ///
    /// `write` writes the new contents to the URL it's given, a temporary file on the
    /// document's volume, which then replaces the document as `NSDocument`'s safe saving does.
    /// The document's other extended attributes are kept too. The app needs write access to
    /// the document. `write` runs on the service's executor and the replacement runs to
    /// completion even when the caller is cancelled, so the document is never left half
    /// saved. Replacing works on every platform, though only macOS and Mac Catalyst have
    /// document-scoped bookmarks.
    ///
    /// ```swift
    /// try await documents.replaceDocument { url in
    ///     try encoder.encode(project).write(to: url)
    /// }
    /// ```
    ///
    /// Fails with the classified error `write` or the replacement throws, such as
    /// ``BookmarkFailure/missing`` when `write` wrote nothing.
    public func replaceDocument(_ write: @escaping @Sendable (URL) throws -> Void) async throws(BookmarkError) {
        let engine = service.engine
        let classifier = service.classifier
        let document = document
        let result = await service.executor.perform { () -> Result<Void, BookmarkError> in
            do {
                try engine.replaceItem(at: document, writing: write)
                return .success(())
            } catch {
                let failure = classifier.classify(error, recorded: nil)
                return .failure(BookmarkError(failure, lastKnownPath: document.path(percentEncoded: false), underlying: error))
            }
        }
        try result.get()
    }

    /// Replaces the document atomically with `contents`, keeping the key its bookmarks depend
    /// on. See ``replaceDocument(_:)``.
    public func replaceDocument(with contents: Data) async throws(BookmarkError) {
        try await replaceDocument { url in
            try contents.write(to: url)
        }
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
