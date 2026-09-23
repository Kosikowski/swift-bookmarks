@testable import Bookmarks
import BookmarksTesting
import Foundation

enum Fixtures {
    static let sandboxedMac = SandboxEnvironment(platform: .macOS, isSandboxed: true)
    static let unsandboxedMac = SandboxEnvironment(platform: .macOS, isSandboxed: false)
    static let iOS = SandboxEnvironment(platform: .iOS, isSandboxed: true)

    static let executor = BlockingExecutor(label: "tests.blocking", width: 8)

    static func engine(_ environment: SandboxEnvironment = sandboxedMac) -> FakeBookmarkEngine {
        FakeBookmarkEngine(environment: environment)
    }

    static func bookmarks(_ engine: FakeBookmarkEngine, timeout: Duration? = nil) -> Bookmarks {
        Bookmarks(engine: engine, executor: executor, timeout: timeout)
    }

    static func adoptFolder(
        _ path: String,
        engine: FakeBookmarkEngine,
        kind: BookmarkKind = .appScoped(.readWrite)
    ) async throws -> BookmarkData {
        engine.addItem(at: path)
        let bookmarks = bookmarks(engine)
        return try await bookmarks.adopt(engine.grant(path, origin: .openPanel), kind: kind).data
    }
}

extension BookmarkError {
    var isMissing: Bool { failure == .missing }
}
