import Bookmarks
import Foundation

/// A folder of the test's own in the user's Downloads folder, which the host reaches through
/// its `downloads.read-write` entitlement.
///
/// The container and the temporary folder won't do: the system refuses document-scoped
/// bookmarks to items there. Xcode gives hosted tests read access to every path, so these
/// tests check what the sandbox does to bookmarks, not whether it denies reads.
struct SandboxFolder {
    let root: URL

    init() throws {
        root = SandboxEnvironment.realHomeDirectory
            .appending(path: "Downloads/swift-bookmarks-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL {
        root.appending(path: name)
    }

    @discardableResult
    func file(_ name: String, _ contents: String = "contents") throws -> URL {
        let url = url(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func fileID(of url: URL) -> UInt64? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.fileIdentifierKey]))?.fileIdentifier
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension BookmarkService {
    /// A service for the tests, with a short timeout so a hung system agent fails a test
    /// instead of stalling the run.
    static var hosted: BookmarkService {
        BookmarkService(timeout: .seconds(10), ledger: ScopeLedger())
    }
}

extension Grant {
    /// A grant for an item the host reaches through its entitlements.
    static func reachable(_ url: URL) -> Grant {
        Grant(url: url, origin: .alreadyAccessible)
    }
}
