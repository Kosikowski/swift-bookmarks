@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: adding")
struct StoreAddTests {
    let harness = StoreHarness()

    @Test func storesTheGrantedItem() async throws {
        let record = try await harness.add("docs", "/Users/me/Documents/Work", name: "Work")

        #expect(record.key == "docs")
        #expect(record.metadata == Tag(name: "Work"))
        #expect(record.kind == .appScoped(.readWrite))
        #expect(record.lastKnownPath == "/Users/me/Documents/Work")
        #expect(record.displayName == "Work")
        #expect(record.status == .available)
        #expect(record.createdAt == harness.clock.now)
        #expect(record.refreshedAt == nil)
        #expect(record.fileIdentity != nil)
        #expect(try harness.store.records() == [record])
        #expect(harness.saved == [record])
        #expect(harness.engine.isBalanced)
    }

    @Test func publishesAnAddedChange() async throws {
        let changes = harness.store.changes()

        try await harness.add("a", "/Users/me/A")

        #expect(await collect(changes, count: 1) == [.added("a")])
    }

    @Test func replacesTheRecordForAnExistingKey() async throws {
        let first = try await harness.add("a", "/Users/me/A")
        harness.clock.advance(by: 60)

        let second = try await harness.store.add(harness.grant("/Users/me/B"), key: "a", metadata: Tag(name: "B"))

        #expect(second.createdAt == first.createdAt)
        #expect(second.refreshedAt == harness.clock.now)
        #expect(second.lastKnownPath == "/Users/me/B")
        #expect(second.metadata.name == "B")
        #expect(try harness.store.keys() == ["a"])
    }

    @Test func keepsInsertionOrder() async throws {
        try await harness.add("c", "/C")
        try await harness.add("a", "/A")
        try await harness.add("b", "/B")

        #expect(try harness.store.keys() == ["c", "a", "b"])
        #expect(harness.saved.map(\.key) == ["c", "a", "b"])
    }

    @Test func conveniencesForGeneratedKeysAndNoMetadata() async throws {
        let engine = Fixtures.engine()
        let store = BookmarkStore<BookmarkID, NoMetadata>(
            persistence: InMemoryPersistence(),
            service: Fixtures.service(engine)
        )
        engine.addItem(at: "/A")
        engine.addItem(at: "/B")

        let first = try await store.add(engine.grant("/A", origin: .openPanel))
        let second = try await store.add(engine.grant("/B", origin: .openPanel), metadata: NoMetadata())

        #expect(first.key != second.key)
        #expect(try store.records().count == 2)
    }

    @Test func noMetadataConvenienceWithAKey() async throws {
        let engine = Fixtures.engine()
        let store = BookmarkStore<String, NoMetadata>(persistence: InMemoryPersistence(), service: Fixtures.service(engine))
        engine.addItem(at: "/A")

        let record = try await store.add(engine.grant("/A", origin: .openPanel), key: "a")

        #expect(record.key == "a")
    }

    @Test func usesTheStoresKind() async throws {
        let engine = Fixtures.engine()
        let store = TestStore(persistence: InMemoryPersistence(), kind: .appScoped(.readOnly), service: Fixtures.service(engine))
        engine.addItem(at: "/A")

        let record = try await store.add(engine.grant("/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))

        #expect(record.kind == .appScoped(.readOnly))
        #expect(engine.creationRequests.last?.options == [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
    }

    @Test func defaultsToTheEnvironmentsKind() {
        let iOSStore = TestStore(persistence: InMemoryPersistence(), service: Fixtures.service(Fixtures.engine(Fixtures.iOS)))
        let directStore = TestStore(persistence: InMemoryPersistence(), service: Fixtures.service(Fixtures.engine(Fixtures.unsandboxedMac)))

        #expect(iOSStore.kind == .implicit)
        #expect(directStore.kind == .reference)
    }

    @Suite("Duplicates")
    struct Duplicates {
        @Test func rejectedByDefault() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.add(harness.grant("/Users/me/A"), key: "b", metadata: Tag(name: "b"))
            }

            guard case .duplicate(of: "a") = error else {
                Issue.record("Expected duplicate of a, got \(String(describing: error))")
                return
            }
            #expect(try harness.store.keys() == ["a"])
            #expect(harness.engine.isBalanced)
        }

        @Test func detectedByIdentityAfterAMove() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Moved")

            await #expect(throws: TestStore.Failure.self) {
                try await harness.store.add(harness.engine.grant("/Users/me/Moved", origin: .openPanel), key: "b", metadata: Tag(name: "b"))
            }
        }

        @Test func detectedByPathWhenIdentityIsUnknown() async throws {
            let existing = TestRecord(
                key: "legacy",
                data: BookmarkData(Data("old".utf8)),
                kind: .appScoped(.readWrite),
                lastKnownPath: "/Users/me/A",
                createdAt: Date(),
                metadata: Tag(name: "legacy")
            )
            let harness = StoreHarness(records: [existing])

            await #expect(throws: TestStore.Failure.self) {
                try await harness.add("b", "/Users/me/A")
            }
        }

        @Test func canReturnTheExistingRecord() async throws {
            let harness = StoreHarness(policy: StorePolicy(duplicates: .returnExisting))
            let original = try await harness.add("a", "/Users/me/A")

            let returned = try await harness.add("b", "/Users/me/A")

            #expect(returned == original)
            #expect(try harness.store.keys() == ["a"])
            #expect(harness.engine.isBalanced)
        }

        @Test func canBeAllowed() async throws {
            let harness = StoreHarness(policy: StorePolicy(duplicates: .allow))

            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/A")

            #expect(try harness.store.keys() == ["a", "b"])
        }

        @Test func replacingTheSameKeyIsNotADuplicate() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")

            try await harness.add("a", "/Users/me/A")

            #expect(try harness.store.keys() == ["a"])
        }
    }

    @Suite("Validation")
    struct Validation {
        @Test func refusalsAreReportedAndNothingIsStored() async throws {
            let harness = StoreHarness(policy: StorePolicy(validators: [.fileOnly]))

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.add("a", "/Users/me/Folder")
            }

            #expect(error?.bookmarkFailure == .refused(.notFile(path: "/Users/me/Folder")))
            #expect(try harness.store.records().isEmpty)
            #expect(harness.engine.isBalanced)
        }

        @Test func validatorsSeeOtherRecordsButNotTheKeyBeingReplaced() async throws {
            let harness = StoreHarness(policy: StorePolicy(validators: [.noOverlap]))
            try await harness.add("parent", "/Users/me/Projects")
            try await harness.add("other", "/Users/me/Other")

            try await harness.add("other", "/Users/me/Other")
            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.add("child", "/Users/me/Projects/App")
            }

            #expect(error?.bookmarkFailure == .refused(.insideExisting(existing: "/Users/me/Projects")))
        }
    }

    @Suite("Failures")
    struct Failures {
        @Test func adoptionFailuresAreBookmarkErrors() async {
            let harness = StoreHarness()
            harness.engine.addItem(at: "/Users/me/A")
            harness.engine.failCreation(of: "/Users/me/A", with: FakeErrors.denied)

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.add(harness.engine.grant("/Users/me/A", origin: .appKitDrop), key: "a", metadata: Tag(name: "a"))
            }

            #expect(error?.bookmarkFailure == .denied)
            #expect(harness.engine.isBalanced)
        }

        @Test func aFailedSaveLeavesTheStoreUnchanged() async throws {
            let harness = StoreHarness()
            harness.persistence.failSaves(1)

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.add("a", "/Users/me/A")
            }

            guard case .persistence(let persistenceError) = error else {
                Issue.record("Expected a persistence error, got \(String(describing: error))")
                return
            }
            #expect(persistenceError.reason == .writeFailed)
            #expect(try harness.store.records().isEmpty)
            #expect(harness.engine.isBalanced)
        }

        @Test func aFailedLoadIsRetriedLater() async throws {
            let harness = StoreHarness()
            harness.persistence.failLoads(1)

            #expect(throws: TestStore.Failure.self) { try harness.store.records() }

            #expect(try harness.store.records().isEmpty)
        }

        @Test func aFailedLoadRelinquishesTheGrant() async {
            let harness = StoreHarness()
            harness.persistence.failLoads(1)

            await #expect(throws: TestStore.Failure.self) {
                try await harness.add("a", "/Users/me/A")
            }

            #expect(harness.engine.isBalanced)
        }
    }
}
