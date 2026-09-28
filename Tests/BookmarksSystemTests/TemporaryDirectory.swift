@testable import Bookmarks
import Foundation

/// A folder of real files for one test, removed with ``remove()``.
struct TemporaryDirectory {
    let root = FileManager.default.temporaryDirectory.appending(path: "swift-bookmarks-system-\(UUID().uuidString)", directoryHint: .isDirectory)

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    func makeDirectory(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFile(_ relative: String, contents: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func canonical(_ url: URL) -> String {
        NormalizedPath(url.resolvingSymlinksInPath()).string
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
