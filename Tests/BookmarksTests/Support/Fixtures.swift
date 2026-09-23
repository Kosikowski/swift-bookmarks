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

    /// A service with its own ledger, so tests running in parallel don't see each other's scopes.
    static func service(_ engine: FakeBookmarkEngine, timeout: Duration? = nil) -> BookmarkService {
        BookmarkService(engine: engine, executor: executor, timeout: timeout, ledger: ScopeLedger())
    }

    static func adoptFolder(
        _ path: String,
        engine: FakeBookmarkEngine,
        kind: BookmarkKind = .appScoped(.readWrite)
    ) async throws -> BookmarkData {
        engine.addItem(at: path)
        let service = service(engine)
        return try await service.adopt(engine.grant(path, origin: .openPanel), kind: kind).data
    }
}

extension BookmarkError {
    var isMissing: Bool { failure == .missing }
}
