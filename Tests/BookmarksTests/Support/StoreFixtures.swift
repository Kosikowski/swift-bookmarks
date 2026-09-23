@testable import Bookmarks
import BookmarksTesting
import Foundation
import Synchronization

struct Tag: Codable, Sendable, Hashable {
    var name: String
}

typealias TestStore = BookmarkStore<String, Tag>
typealias TestRecord = BookmarkRecord<String, Tag>

final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0.addTimeInterval(seconds) }
    }

    var function: @Sendable () -> Date {
        { [self] in now }
    }
}

struct StoreHarness {
    let engine: FakeBookmarkEngine
    let persistence: ScriptedPersistence<String, Tag>
    let clock = TestClock()
    let store: TestStore

    init(
        environment: SandboxEnvironment = Fixtures.sandboxedMac,
        policy: StorePolicy = .default,
        validatorsForKey: @escaping @Sendable (String) -> [any GrantValidator] = { _ in [] },
        records: [TestRecord] = [],
        timeout: Duration? = nil
    ) {
        engine = FakeBookmarkEngine(environment: environment)
        persistence = ScriptedPersistence(records: records)
        store = TestStore(
            persistence: persistence,
            policy: policy,
            validatorsForKey: validatorsForKey,
            service: Fixtures.service(engine, timeout: timeout),
            now: clock.function
        )
    }

    var saved: [TestRecord] { persistence.storedRecords }

    func grant(_ path: String, origin: Grant.Origin = .openPanel, isDirectory: Bool = true) -> Grant {
        engine.addItem(at: path, isDirectory: isDirectory)
        return engine.grant(path, origin: origin)
    }

    @discardableResult
    func add(_ key: String, _ path: String, name: String? = nil) async throws -> TestRecord {
        try await store.add(grant(path), key: key, metadata: Tag(name: name ?? key))
    }
}

func collect<Key, Metadata>(_ stream: AsyncStream<StoreUpdate<Key, Metadata>>, count: Int) async -> [String] {
    var changes: [String] = []
    for await update in stream {
        guard case .change(let change) = update else { continue }
        changes.append(change.summary)
        if changes.count == count { break }
    }
    return changes
}

extension StoreChange {
    var summary: String {
        switch self {
        case .added(let record): "added \(record.key)"
        case .updated(let record): "updated \(record.key)"
        case .removed(let key): "removed \(key)"
        case .reordered(let keys): "reordered \(keys.map { "\($0)" }.joined(separator: ","))"
        }
    }
}
