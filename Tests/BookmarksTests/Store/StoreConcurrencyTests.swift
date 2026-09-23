@testable import Bookmarks
import BookmarksTesting
import Foundation
import Synchronization
import Testing

@Suite("BookmarkStore: concurrency")
struct StoreConcurrencyTests {
    @Test func mixedOperationsStayConsistentAndBalanced() async throws {
        let harness = StoreHarness(policy: StorePolicy(duplicates: .allow))
        let keys = (0..<12).map { "item-\($0)" }
        for key in keys {
            try await harness.add(key, "/Items/\(key)")
        }
        let store = harness.store
        let engine = harness.engine

        await withTaskGroup(of: Void.self) { group in
            for round in 0..<240 {
                let key = keys[round % keys.count]
                group.addTask {
                    switch round % 6 {
                    case 0, 1, 2:
                        if let lease = try? await store.lease(key) {
                            await Task.yield()
                            lease.end()
                        }
                    case 3:
                        try? await store.updateMetadata(key) { $0.name = "round \(round)" }
                    case 4:
                        engine.addItem(at: "/Regranted/\(key)")
                        _ = try? await store.regrant(key, with: engine.grant("/Regranted/\(key)", origin: .openPanel))
                    default:
                        _ = try? await store.withAccess(to: [key, keys[(round + 1) % keys.count]]) { $0.count }
                    }
                }
            }
        }

        #expect(engine.isBalanced)
        #expect(try await store.keys() == keys)
        #expect(harness.saved.map(\.key) == keys)
        #expect(try await store.records().map(\.data) == harness.saved.map(\.data))
        #expect(store.registry.activeKeys.isEmpty)
    }

    @Test func concurrentAddsOfTheSameItemKeepOneRecord() async throws {
        let harness = StoreHarness(policy: StorePolicy(duplicates: .returnExisting))
        harness.engine.addItem(at: "/Shared")
        let store = harness.store
        let engine = harness.engine

        let keys = await withTaskGroup(of: String?.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await store.add(engine.grant("/Shared", origin: .openPanel), key: "k\(index)", metadata: Tag(name: "\(index)")).key
                }
            }
            return await group.reduce(into: Set<String>()) { result, key in
                if let key { result.insert(key) }
            }
        }

        #expect(keys.count == 1)
        #expect(try await store.records().count == 1)
        #expect(harness.engine.isBalanced)
    }

    @Test func forgettingWhileLeasingNeverLeaksAccess() async throws {
        let harness = StoreHarness()
        let store = harness.store
        for index in 0..<10 {
            try await harness.add("k\(index)", "/Items/\(index)")
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    for _ in 0..<5 {
                        if let lease = try? await store.lease("k\(index)") {
                            lease.end()
                        }
                    }
                }
                group.addTask {
                    _ = try? await store.forget("k\(index)")
                }
            }
        }

        #expect(harness.engine.isBalanced)
        #expect(try await store.records().isEmpty)
    }

    @Test func subscribersReplayingEveryChangeEndWithTheStoredRecords() async throws {
        let harness = StoreHarness(policy: StorePolicy(duplicates: .allow))
        let keys = (0..<8).map { "item-\($0)" }
        for key in keys {
            try await harness.add(key, "/Items/\(key)")
        }
        let store = harness.store
        let updates = try await store.updates()
        let replay = Task {
            var records: [TestRecord] = []
            for await update in updates {
                switch update {
                case .snapshot(let snapshot): records = snapshot
                case .change(.added(let record)): records.append(record)
                case .change(.updated(let record)): records = records.map { $0.key == record.key ? record : $0 }
                case .change(.removed(let key)): records.removeAll { $0.key == key }
                case .change(.reordered(let order)): records = order.compactMap { key in records.first { $0.key == key } }
                }
                if case .change(.updated(let record)) = update, record.metadata.name == "last" {
                    break
                }
            }
            return records
        }

        await withTaskGroup(of: Void.self) { group in
            for round in 0..<160 {
                let key = keys[round % keys.count]
                let priority: TaskPriority = [.low, .medium, .high][round % 3]
                group.addTask(priority: priority) {
                    switch round % 4 {
                    case 0, 1: try? await store.updateMetadata(key) { $0.name = "round \(round)" }
                    case 2: try? await store.move(key, to: round % keys.count)
                    default: try? await store.lease(key).end()
                    }
                }
            }
        }
        let first = try #require(try await store.keys().first)
        try await store.updateMetadata(first) { $0.name = "last" }

        #expect(await replay.value == (try await store.records()))
    }

    /// Passes changes to `base`, blocking the first one until `release` is signalled.
    final class BlockingPersistence: BookmarkPersistence, Sendable {
        let base: ScriptedPersistence<String, Tag>
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let blocked = Atomic(false)

        init(records: [TestRecord]) {
            base = ScriptedPersistence(records: records)
        }

        func load() throws(PersistenceError) -> [TestRecord] { try base.load() }
        func save(_ records: [TestRecord]) throws(PersistenceError) { try base.save(records) }
        func update(_ transform: ([TestRecord]) -> [TestRecord]?) throws(PersistenceError) {
            if !blocked.exchange(true, ordering: .relaxed) {
                entered.signal()
                release.wait()
            }
            try base.update(transform)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledQueuedChangeKeepsMemoryAndStorageInStep() async throws {
        let records = ["a", "b"].map { StoreLoadingTests.record($0) }
        let persistence = BlockingPersistence(records: records)
        let store = TestStore(persistence: persistence, service: Fixtures.service(Fixtures.engine()))
        try await store.load()

        let first = Task { try await store.updateMetadata("a") { $0.name = "first" } }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { persistence.entered.wait(); continuation.resume() }
        }
        let queued = Task { try await store.updateMetadata("b") { $0.name = "queued" } }
        await Task.yield()
        queued.cancel()
        persistence.release.signal()
        try await first.value
        _ = await queued.result

        #expect(try await store.records() == persistence.base.storedRecords)
        #expect(try await store.record("a")?.metadata.name == "first")
    }
}
