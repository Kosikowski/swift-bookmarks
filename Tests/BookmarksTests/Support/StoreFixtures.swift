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

final class ScriptedPersistence<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: BookmarkPersistence {
    let base: InMemoryPersistence<Key, Metadata>
    private let failures = Mutex((load: 0, save: 0))

    init(records: [BookmarkRecord<Key, Metadata>] = []) {
        base = InMemoryPersistence(records: records)
    }

    func failLoads(_ count: Int) {
        failures.withLock { $0.load = count }
    }

    func failSaves(_ count: Int) {
        failures.withLock { $0.save = count }
    }

    func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let fail = failures.withLock { state -> Bool in
            guard state.load > 0 else { return false }
            state.load -= 1
            return true
        }
        if fail { throw PersistenceError(.readFailed) }
        return try base.load()
    }

    func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        let fail = failures.withLock { state -> Bool in
            guard state.save > 0 else { return false }
            state.save -= 1
            return true
        }
        if fail { throw PersistenceError(.writeFailed) }
        try base.save(records)
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
        records: [TestRecord] = [],
        timeout: Duration? = nil
    ) {
        engine = FakeBookmarkEngine(environment: environment)
        persistence = ScriptedPersistence(records: records)
        store = TestStore(
            persistence: persistence,
            policy: policy,
            service: Fixtures.service(engine, timeout: timeout),
            now: clock.function
        )
    }

    var saved: [TestRecord] { persistence.base.storedRecords }

    func grant(_ path: String, origin: Grant.Origin = .openPanel, isDirectory: Bool = true) -> Grant {
        engine.addItem(at: path, isDirectory: isDirectory)
        return engine.grant(path, origin: origin)
    }

    @discardableResult
    func add(_ key: String, _ path: String, name: String? = nil) async throws -> TestRecord {
        try await store.add(grant(path), key: key, metadata: Tag(name: name ?? key))
    }
}

func collect<Key>(_ stream: AsyncStream<StoreChange<Key>>, count: Int) async -> [StoreChange<Key>] {
    var changes: [StoreChange<Key>] = []
    for await change in stream {
        changes.append(change)
        if changes.count == count { break }
    }
    return changes
}
