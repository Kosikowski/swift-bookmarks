public import Foundation

/// The ``BookmarkEngine`` backed by Foundation's URL bookmark APIs.
public struct SystemBookmarkEngine: BookmarkEngine {
    public let environment: SandboxEnvironment

    /// Creates an engine for the current process.
    public init(environment: SandboxEnvironment = .current) {
        self.environment = environment
    }

    public func makeBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        includingResourceValuesFor keys: Set<URLResourceKey>,
        relativeTo document: URL?
    ) throws -> BookmarkData {
        let data = try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: keys.isEmpty ? nil : keys,
            relativeTo: document
        )
        return BookmarkData(data)
    }

    public func resolve(
        _ data: BookmarkData,
        options: URL.BookmarkResolutionOptions,
        relativeTo document: URL?
    ) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data.rawValue,
            options: options,
            relativeTo: document,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    public func recordedValues(in data: BookmarkData) -> RecordedValues? {
        let keys: Set<URLResourceKey> = [.pathKey, .nameKey, .volumeURLKey, .volumeNameKey, .isDirectoryKey]
        guard let values = URL.resourceValues(forKeys: keys, fromBookmarkData: data.rawValue) else {
            return nil
        }
        let recorded = RecordedValues(
            path: values.path,
            name: values.name,
            volumePath: values.volume?.path(percentEncoded: false).trimmingTrailingSlash,
            volumeName: values.volumeName,
            isDirectory: values.isDirectory
        )
        return recorded == RecordedValues() ? nil : recorded
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    public func itemExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func fileIdentity(of url: URL) -> FileIdentity? {
        guard
            let values = try? url.uncachedResourceValues(forKeys: [.fileIdentifierKey, .volumeUUIDStringKey]),
            let fileID = values.fileIdentifier
        else {
            return nil
        }
        return FileIdentity(volumeUUID: values.volumeUUIDString, fileID: fileID)
    }

    public func itemInfo(at url: URL) -> ItemInfo? {
        guard let values = try? url.uncachedResourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return nil
        }
        return ItemInfo(
            isDirectory: values.isDirectory ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            canonicalPath: url.resolvingSymlinksInPath().path(percentEncoded: false).trimmingTrailingSlash
        )
    }

    public func writeAliasFile(_ data: BookmarkData, to url: URL) throws {
        try URL.writeBookmarkData(data.rawValue, to: url)
    }

    public func aliasFileData(at url: URL) throws -> BookmarkData {
        BookmarkData(try URL.bookmarkData(withContentsOf: url))
    }
}

extension URL {
    func uncachedResourceValues(forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var url = self
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: keys)
    }
}

extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
