public import Foundation

/// Writes and resolves Finder alias files.
///
/// Alias files carry no security scope. Writing one needs access to the folder that will
/// contain it, and resolving one gives a URL that is only usable where the app already has
/// access.
public struct AliasFiles: Sendable {
    /// The bookmark service.
    public let service: BookmarkService

    init(service: BookmarkService) {
        self.service = service
    }

    /// Writes an alias file at `aliasURL` that points to the granted item.
    ///
    /// The grant is relinquished whether or not writing succeeds.
    public func write(aliasTo grant: Grant, at aliasURL: URL) async throws(BookmarkError) {
        let data = try await service.consuming(grant) { () throws(BookmarkError) -> BookmarkData in
            try await service.create(for: grant, kind: .alias)
        }
        let engine = service.engine
        let classifier = service.classifier
        try await service.run { () throws(BookmarkError) in
            do {
                try engine.writeAliasFile(data, to: aliasURL)
            } catch {
                throw BookmarkError(classifier.classify(error, recorded: nil), lastKnownPath: aliasURL.path(percentEncoded: false), underlying: error as NSError)
            }
        }
    }

    /// Reads the bookmark stored in the alias file at `aliasURL`.
    public func data(inAliasAt aliasURL: URL) async throws(BookmarkError) -> BookmarkData {
        let engine = service.engine
        let classifier = service.classifier
        return try await service.run { () throws(BookmarkError) -> BookmarkData in
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
        return try await service.resolve(data, kind: .alias, policy: policy)
    }
}
