@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: changing records")
struct StoreMutationTests {
    let harness = StoreHarness()

    @Suite("Forgetting")
    struct Forgetting {
        let harness = StoreHarness()

        @Test func removesTheRecord() async throws {
            try await harness.add("a", "/Users/me/A")
            let changes = harness.store.changes()

            #expect(try await harness.store.forget("a"))

            #expect(try harness.store.records().isEmpty)
            #expect(harness.saved.isEmpty)
            #expect(await collect(changes, count: 1) == [.removed("a")])
        }

        @Test func forgettingAnUnknownKeyChangesNothing() async throws {
            #expect(try await !harness.store.forget("nope"))
            #expect(harness.persistence.base.saveCount == 0)
        }

        @Test func activeLeasesSurviveButNewOnesFail() async throws {
            try await harness.add("a", "/Users/me/A")
            let lease = try await harness.store.lease("a")

            try await harness.store.forget("a")

            #expect(lease.isActive)
            #expect(harness.store.activeLease(for: "a") == nil)
            await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }
            lease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func removeAllClearsEverything() async throws {
            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")
            let changes = harness.store.changes()

            try await harness.store.removeAll()

            #expect(try harness.store.records().isEmpty)
            #expect(Set(await collect(changes, count: 2)) == [.removed("a"), .removed("b")])
        }
    }

    @Suite("Re-granting")
    struct Regranting {
        let harness = StoreHarness()

        @Test func replacesTheBytesAndKeepsEverythingElse() async throws {
            let original = try await harness.add("a", "/Users/me/A", name: "Project")
            harness.clock.advance(by: 10)

            let regranted = try await harness.store.regrant("a", with: harness.grant("/Users/me/Elsewhere"))

            #expect(regranted.key == "a")
            #expect(regranted.metadata == original.metadata)
            #expect(regranted.createdAt == original.createdAt)
            #expect(regranted.refreshedAt == harness.clock.now)
            #expect(regranted.data != original.data)
            #expect(regranted.lastKnownPath == "/Users/me/Elsewhere")
            #expect(harness.engine.isBalanced)
        }

        @Test func restoresAvailability() async throws {
            try await harness.add("a", "/Users/me/A")
            harness.engine.removeItem(at: "/Users/me/A")
            _ = try? await harness.store.lease("a")

            try await harness.store.regrant("a", with: harness.grant("/Users/me/A"))

            #expect(try harness.store.record("a")?.status == .available)
            try await harness.store.lease("a").end()
        }

        @Test func newLeasesUseTheNewItemWhileOldOnesContinue() async throws {
            try await harness.add("a", "/Users/me/A")
            let old = try await harness.store.lease("a")

            try await harness.store.regrant("a", with: harness.grant("/Users/me/B"))
            let fresh = try await harness.store.lease("a")

            #expect(old.isActive)
            #expect(fresh.url.path(percentEncoded: false) == "/Users/me/B/")
            old.end()
            fresh.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func unknownKeysRelinquishTheGrant() async {
            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.regrant("nope", with: harness.grant("/Users/me/A"))
            }

            guard case .notFound("nope") = error else {
                Issue.record("Expected notFound, got \(String(describing: error))")
                return
            }
            #expect(harness.engine.isBalanced)
        }

        @Test func canRequireTheSameItem() async throws {
            let harness = StoreHarness(policy: StorePolicy(requiresSameItemOnRegrant: true))
            let original = try await harness.add("a", "/Users/me/A")

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.regrant("a", with: harness.grant("/Users/me/Other"))
            }

            guard case .differentItem("a") = error else {
                Issue.record("Expected differentItem, got \(String(describing: error))")
                return
            }
            #expect(try harness.store.record("a")?.data == original.data)
            #expect(harness.engine.isBalanced)
        }

        @Test func acceptsTheSameItemAfterAMove() async throws {
            let harness = StoreHarness(policy: StorePolicy(requiresSameItemOnRegrant: true))
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Moved")

            let record = try await harness.store.regrant("a", with: harness.engine.grant("/Users/me/Moved", origin: .openPanel))

            #expect(record.lastKnownPath == "/Users/me/Moved")
        }

        @Test func validatorsIgnoreTheRecordBeingRegranted() async throws {
            let harness = StoreHarness(policy: StorePolicy(validators: [.noOverlap]))
            try await harness.add("a", "/Users/me/A")

            try await harness.store.regrant("a", with: harness.grant("/Users/me/A/Inner"))
        }
    }

    @Suite("Metadata and order")
    struct MetadataAndOrder {
        let harness = StoreHarness()

        @Test func updatesMetadata() async throws {
            try await harness.add("a", "/Users/me/A", name: "Old")

            try await harness.store.updateMetadata("a") { $0.name = "New" }

            #expect(try harness.store.record("a")?.metadata.name == "New")
            #expect(harness.saved.first?.metadata.name == "New")
        }

        @Test func updatingUnknownKeysFails() async {
            await #expect(throws: TestStore.Failure.self) {
                try await harness.store.updateMetadata("nope") { $0.name = "x" }
            }
        }

        @Test func movesRecords() async throws {
            try await harness.add("a", "/A")
            try await harness.add("b", "/B")
            try await harness.add("c", "/C")

            try await harness.store.move("c", to: 0)
            #expect(try harness.store.keys() == ["c", "a", "b"])

            try await harness.store.move("c", to: 99)
            #expect(try harness.store.keys() == ["a", "b", "c"])

            try await harness.store.move("b", to: -5)
            #expect(try harness.store.keys() == ["b", "a", "c"])
            #expect(harness.saved.map(\.key) == ["b", "a", "c"])
        }

        @Test func movingUnknownKeysFails() async {
            await #expect(throws: TestStore.Failure.self) { try await harness.store.move("nope", to: 0) }
        }
    }

    @Suite("Recents")
    struct Recents {
        let harness = StoreHarness(policy: .recents(limit: 3))

        @Test func newestFirst() async throws {
            try await harness.add("a", "/A")
            try await harness.add("b", "/B")
            try await harness.add("c", "/C")

            #expect(try harness.store.keys() == ["c", "b", "a"])
        }

        @Test func leasingMovesToTheFront() async throws {
            try await harness.add("a", "/A")
            try await harness.add("b", "/B")

            try await harness.store.lease("a").end()

            #expect(try harness.store.keys() == ["a", "b"])
        }

        @Test func evictsTheOldestBeyondTheLimit() async throws {
            for name in ["a", "b", "c"] {
                try await harness.add(name, "/\(name)")
            }
            let changes = harness.store.changes()

            try await harness.add("d", "/d")

            #expect(try harness.store.keys() == ["d", "c", "b"])
            #expect(harness.saved.map(\.key) == ["d", "c", "b"])
            #expect(await collect(changes, count: 2) == [.added("d"), .removed("a")])
        }

        @Test func addingAnExistingItemReturnsItAndMovesItToTheFront() async throws {
            let first = try await harness.add("a", "/A")
            try await harness.add("b", "/B")

            let again = try await harness.add("other", "/A")

            #expect(again.key == first.key)
            #expect(try harness.store.keys().count == 2)
        }

        @Test func keepsUnavailableItems() async throws {
            try await harness.add("a", "/A")
            harness.engine.removeItem(at: "/A")

            _ = try? await harness.store.lease("a")

            #expect(try harness.store.contains("a"))
        }
    }

    @Suite("Stored data")
    struct StoredData {
        @Test func loadsExistingRecordsLazilyInStoredOrder() throws {
            let records = ["z", "y", "x"].map {
                TestRecord(key: $0, data: BookmarkData(Data($0.utf8)), kind: .appScoped(.readWrite), lastKnownPath: "/\($0)", createdAt: Date(), metadata: Tag(name: $0))
            }
            let harness = StoreHarness(records: records)

            #expect(try harness.store.keys() == ["z", "y", "x"])
            #expect(try harness.store.records() == records)
        }

        @Test func unresolvableRecordsSurviveUnrelatedWrites() async throws {
            let unresolvable = TestRecord(
                key: "offline",
                data: BookmarkData(Data("bytes from an unmounted disk".utf8)),
                kind: .appScoped(.readWrite),
                lastKnownPath: "/Volumes/Offline/Builds",
                status: .unavailable(.volumeUnavailable(name: "Offline"), since: Date(timeIntervalSince1970: 0)),
                createdAt: Date(timeIntervalSince1970: 0),
                metadata: Tag(name: "offline")
            )
            let harness = StoreHarness(records: [unresolvable])
            _ = try? await harness.store.lease("offline")

            try await harness.add("new", "/Users/me/New")
            try await harness.store.forget("new")

            #expect(harness.saved.map(\.key) == ["offline"])
            #expect(harness.saved.first?.data == unresolvable.data)
        }

        @Test func findsKeysByIdentityAfterAMove() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Moved")

            #expect(try await harness.store.key(matching: URL(filePath: "/Users/me/Moved")) == "a")
        }

        @Test func findsKeysByPathWhenTheItemIsGone() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.removeItem(at: "/Users/me/A")

            #expect(try await harness.store.key(matching: URL(filePath: "/Users/me/A/")) == "a")
            #expect(try await harness.store.key(matching: URL(filePath: "/Users/me/B")) == nil)
        }

        @Test func checksAvailability() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")

            #expect(try await harness.store.availability("a") == .available)
            harness.engine.removeItem(at: "/Users/me/A")
            #expect(try await harness.store.availability("a") == .missing)
            await #expect(throws: TestStore.Failure.self) { try await harness.store.availability("nope") }
        }

        @Test func everySubscriberSeesChanges() async throws {
            let harness = StoreHarness()
            let first = harness.store.changes()
            let second = harness.store.changes()

            try await harness.add("a", "/A")

            #expect(await collect(first, count: 1) == [.added("a")])
            #expect(await collect(second, count: 1) == [.added("a")])
        }
    }
}
