@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: loading")
struct StoreLoadingTests {
    static func record(_ key: String, data: String? = nil, tag: String? = nil) -> TestRecord {
        TestRecord(
            key: key,
            data: BookmarkData(Data((data ?? key).utf8)),
            kind: .appScoped(.readWrite),
            lastKnownPath: "/\(key)",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: Tag(name: tag ?? key)
        )
    }

    @Test func loadsOnceForConcurrentCallers() async throws {
        let harness = StoreHarness(records: [Self.record("a")])
        let store = harness.store

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try? await store.load() }
            }
        }

        #expect(harness.persistence.loadCount == 1)
        #expect(try await store.keys() == ["a"])
    }

    @Test func aFailedLoadCanBeRetried() async throws {
        let harness = StoreHarness(records: [Self.record("a")])
        harness.persistence.failLoads(1)

        let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.load() }
        try await harness.store.load()

        guard case .persistence(let persistenceError) = error else {
            Issue.record("Expected a persistence error, got \(String(describing: error))")
            return
        }
        #expect(persistenceError.reason == .readFailed)
        #expect(try await harness.store.keys() == ["a"])
    }

    @Suite("Reloading")
    struct Reloading {
        @Test func publishesWhatAnotherProcessChanged() async throws {
            let harness = StoreHarness(records: [StoreLoadingTests.record("kept"), StoreLoadingTests.record("removed"), StoreLoadingTests.record("retagged")])
            try await harness.store.load()
            let changes = try await harness.store.updates()
            harness.persistence.replaceStoredRecords([
                StoreLoadingTests.record("kept"),
                StoreLoadingTests.record("retagged", tag: "new"),
                StoreLoadingTests.record("added"),
            ])

            try await harness.store.reload()

            #expect(await collect(changes, count: 3) == ["removed removed", "added added", "updated retagged"])
            #expect(try await harness.store.keys() == ["kept", "retagged", "added"])
            #expect(try await harness.store.record("retagged")?.metadata.name == "new")
        }

        @Test func loadsWhenNothingWasLoadedYet() async throws {
            let harness = StoreHarness(records: [StoreLoadingTests.record("a")])

            try await harness.store.reload()

            #expect(try await harness.store.keys() == ["a"])
        }

        @Test func detachesRecordsWhoseBytesChanged() async throws {
            let harness = StoreHarness()
            let original = try await harness.add("a", "/Users/me/A")
            let lease = try await harness.store.lease("a")
            harness.engine.addItem(at: "/Users/me/B")
            var replaced = original
            replaced.data = try await Fixtures.adoptFolder("/Users/me/B", engine: harness.engine)
            harness.persistence.replaceStoredRecords([replaced])

            try await harness.store.reload()

            #expect(harness.store.activeLease(for: "a") == nil)
            #expect(lease.isActive)
            let fresh = try await harness.store.lease("a")
            #expect(fresh.url.path(percentEncoded: false) == "/Users/me/B/")
            lease.end()
            fresh.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func failuresLeaveTheRecordsAsTheyWere() async throws {
            let harness = StoreHarness(records: [StoreLoadingTests.record("a")])
            try await harness.store.load()
            harness.persistence.replaceStoredRecords([])
            harness.persistence.failLoads(1)

            await #expect(throws: TestStore.Failure.self) { try await harness.store.reload() }

            #expect(try await harness.store.keys() == ["a"])
        }
    }

    @Suite("Change streams")
    struct ChangeStreams {
        @Test func startWithASnapshotOfTheRecords() async throws {
            let harness = StoreHarness(records: [StoreLoadingTests.record("a"), StoreLoadingTests.record("b")])

            var updates = try await harness.store.updates().makeAsyncIterator()

            #expect(await updates.next() == .snapshot([StoreLoadingTests.record("a"), StoreLoadingTests.record("b")]))
        }

        @Test func carryTheRecordAsItIsAfterTheChange() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Renamed")
            var updates = try await harness.store.updates().makeAsyncIterator()
            _ = await updates.next()

            try await harness.store.lease("a").end()

            guard case .change(.updated(let record))? = await updates.next() else {
                Issue.record("Expected an update")
                return
            }
            #expect(record.lastKnownPath == "/Users/me/Renamed")
            #expect(record == (try await harness.store.record("a")))
        }

        @Test func reportMovesAsReorders() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/A")
            try await harness.add("b", "/B")
            let changes = try await harness.store.updates()

            try await harness.store.move("b", to: 0)

            #expect(await collect(changes, count: 1) == ["reordered b,a"])
        }

        @Test func subscribersJoiningDuringASaveMissNothing() async throws {
            let persistence = StoreWriteIsolationTests.SlowPersistence()
            let engine = Fixtures.engine()
            let store = TestStore(persistence: persistence, service: Fixtures.service(engine))
            engine.addItem(at: "/A")
            let original = try await store.add(engine.grant("/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))
            persistence.blockNextSave()

            let writer = Task { try await store.updateMetadata("a") { $0.name = "renamed" } }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    persistence.saving.wait()
                    continuation.resume()
                }
            }
            var updates = try await store.updates().makeAsyncIterator()
            persistence.release.signal()
            try await writer.value

            #expect(await updates.next() == .snapshot([original]))
            guard case .change(.updated(let record))? = await updates.next() else {
                Issue.record("Expected the metadata update")
                return
            }
            #expect(record.metadata.name == "renamed")
        }

        @Test func boundedStreamsKeepOnlyTheNewestChanges() async throws {
            let harness = StoreHarness()
            let changes = try await harness.store.updates(bufferingPolicy: .bufferingNewest(1))

            try await harness.add("a", "/A")
            try await harness.add("b", "/B")

            #expect(await collect(changes, count: 1) == ["added b"])
        }

        @Test func streamsFinishWhenTheStoreGoesAway() async throws {
            var harness: StoreHarness? = StoreHarness()
            let changes = try await harness!.store.updates()

            harness = nil

            #expect(await collect(changes, count: 1).isEmpty)
        }
    }
}
