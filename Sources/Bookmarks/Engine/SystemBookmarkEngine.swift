public import Foundation

/// The ``BookmarkEngine`` backed by Foundation's URL bookmark APIs.
public struct SystemBookmarkEngine: FileSystemEngine {
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
            volumePath: values.volume.map { NormalizedPath($0).string },
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

    public func isVolumeMounted(atPath path: String) -> Bool {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        return (try? url.uncachedResourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    public func fileIdentity(of url: URL) -> FileIdentity? {
        guard
            let values = try? url.uncachedResourceValues(forKeys: [.fileIdentifierKey, .volumeUUIDStringKey]),
            let fileID = values.fileIdentifier,
            let volumeUUID = values.volumeUUIDString
        else {
            return nil
        }
        return FileIdentity(volumeUUID: volumeUUID, fileID: fileID)
    }

    public func itemInfo(at url: URL) -> ItemInfo? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .volumeSupportsCaseSensitiveNamesKey]
        guard let values = try? url.uncachedResourceValues(forKeys: keys) else {
            return nil
        }
        return ItemInfo(
            isDirectory: values.isDirectory ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            canonicalPath: NormalizedPath(url.resolvingSymlinksInPath()).string,
            namesAreCaseSensitive: values.volumeSupportsCaseSensitiveNames ?? true
        )
    }

    public func namesAreCaseSensitive(at url: URL) -> Bool {
        var components = NormalizedPath(url).components
        while true {
            let candidate = URL(filePath: "/" + components.joined(separator: "/"))
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                let values = try? candidate.uncachedResourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                return values?.volumeSupportsCaseSensitiveNames ?? true
            }
            guard !components.isEmpty else { return true }
            components.removeLast()
        }
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
