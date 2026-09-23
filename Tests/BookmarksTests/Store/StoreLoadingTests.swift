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
            let changes = harness.store.changes()
            try harness.persistence.base.save([
                StoreLoadingTests.record("kept"),
                StoreLoadingTests.record("retagged", tag: "new"),
                StoreLoadingTests.record("added"),
            ])

            try await harness.store.reload()

            #expect(await collect(changes, count: 3) == [.removed("removed"), .updated("retagged"), .added("added")])
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
            try harness.persistence.base.save([replaced])

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
            try harness.persistence.base.save([])
            harness.persistence.failLoads(1)

            await #expect(throws: TestStore.Failure.self) { try await harness.store.reload() }

            #expect(try await harness.store.keys() == ["a"])
        }
    }

    @Suite("Change streams")
    struct ChangeStreams {
        @Test func boundedStreamsKeepOnlyTheNewestChanges() async throws {
            let harness = StoreHarness()
            let changes = harness.store.changes(bufferingPolicy: .bufferingNewest(1))

            try await harness.add("a", "/A")
            try await harness.add("b", "/B")

            #expect(await collect(changes, count: 1) == [.added("b")])
        }

        @Test func streamsFinishWhenTheStoreGoesAway() async {
            var harness: StoreHarness? = StoreHarness()
            let changes = harness!.store.changes()

            harness = nil

            #expect(await collect(changes, count: 1).isEmpty)
        }
    }
}
