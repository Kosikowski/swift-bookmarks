public import Foundation

/// Writes and resolves Finder alias files.
///
/// Alias files carry no security scope. Writing one needs access to the folder that will
/// contain it, and resolving one gives a URL that is only usable where the app already has
/// access.
public struct AliasFiles: Sendable {
    /// The bookmark service.
    public let bookmarks: Bookmarks

    /// Creates an alias helper.
    public init(bookmarks: Bookmarks = Bookmarks()) {
        self.bookmarks = bookmarks
    }

    /// Writes an alias file at `aliasURL` that points to the granted item.
    public func write(aliasTo grant: Grant, at aliasURL: URL) async throws(BookmarkError) {
        let data = try await bookmarks.create(for: grant, kind: .alias)
        let engine = bookmarks.engine
        let classifier = bookmarks.classifier
        try await bookmarks.run { () throws(BookmarkError) in
            do {
                try engine.writeAliasFile(data, to: aliasURL)
            } catch {
                throw BookmarkError(classifier.classify(error, recorded: nil), lastKnownPath: aliasURL.path(percentEncoded: false), underlying: error as NSError)
            }
        }
    }

    /// Reads the bookmark stored in the alias file at `aliasURL`.
    public func data(inAliasAt aliasURL: URL) async throws(BookmarkError) -> BookmarkData {
        let engine = bookmarks.engine
        let classifier = bookmarks.classifier
        return try await bookmarks.run { () throws(BookmarkError) -> BookmarkData in
            do {
                return try engine.aliasFileData(at: aliasURL)
            } catch {
                throw BookmarkError(classifier.classify(error, recorded: nil), lastKnownPath: aliasURL.path(percentEncoded: false), underlying: error as NSError)
            }
        }
    }

    /// Resolves the alias file at `aliasURL` to the item it points to.
    public func resolve(aliasAt aliasURL: URL, policy: ResolutionPolicy = .default) async throws(BookmarkError) -> ResolvedBookmark {
        let data = try await data(inAliasAt: aliasURL)
        return try await bookmarks.resolve(data, kind: .alias, policy: policy)
    }
}
