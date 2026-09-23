@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("Store policy regressions")
struct StorePolicyRegressionTests {
    @Suite("Limits")
    struct Limits {
        @Test func insertionOrderKeepsTheNewestRecords() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 2))

            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")
            try await harness.add("c", "/Users/me/C")

            #expect(try await harness.store.keys() == ["b", "c"])
            #expect(harness.saved.map(\.key) == ["b", "c"])
        }

        @Test func recentsKeepTheMostRecentlyUsed() async throws {
            let harness = StoreHarness(policy: .recents(limit: 2))

            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")
            try await harness.store.lease("a").end()
            try await harness.add("c", "/Users/me/C")

            #expect(try await harness.store.keys() == ["c", "a"])
        }

        @Test func recordsLoadedBeyondTheLimitAreKeptUntilTheNextAdd() async throws {
            let records = ["a", "b", "c", "d"].map { StoreLoadingTests.record($0) }
            let harness = StoreHarness(policy: StorePolicy(limit: 2), records: records)

            #expect(try await harness.store.keys() == ["a", "b", "c", "d"])
            try await harness.store.updateMetadata("a") { $0.name = "renamed" }
            #expect(harness.saved.count == 4)

            try await harness.add("e", "/Users/me/E")

            #expect(try await harness.store.keys() == ["d", "e"])
            #expect(harness.saved.map(\.key) == ["d", "e"])
        }

        @Test func reAddingAStoredKeyAtTheLimitEvictsNothing() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 2))
            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")

            try await harness.add("b", "/Users/me/B2")

            #expect(try await harness.store.keys() == ["a", "b"])
        }
    }

    @Suite("Returning existing records")
    struct ReturningExisting {
        @Test func rePickingABrokenItemRestoresItsRecord() async throws {
            let harness = StoreHarness(policy: .recents(limit: 5))
            let original = try await harness.add("a", "/Users/me/A", name: "Kept")
            harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt, times: 1)
            await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }
            #expect(try await harness.store.record("a")?.status.failure == .needsRegrant)

            let returned = try await harness.add("b", "/Users/me/A")

            #expect(returned.key == "a")
            #expect(returned.metadata == Tag(name: "Kept"))
            #expect(returned.status == .available)
            #expect(returned.data != original.data)
            #expect(returned.createdAt == original.createdAt)
            #expect(try await harness.store.keys() == ["a"])
            #expect(harness.saved.first?.data == returned.data)
            try await harness.store.lease("a").end()
            #expect(harness.engine.isBalanced)
        }

        @Test func theReturnedRecordMovesToTheFrontOfRecents() async throws {
            let harness = StoreHarness(policy: .recents(limit: 5))
            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")

            try await harness.add("c", "/Users/me/A")

            #expect(try await harness.store.keys() == ["a", "b"])
        }
    }

    @Suite("Re-granting")
    struct Regranting {
        @Test(arguments: [DuplicateHandling.reject, .returnExisting])
        func anItemStoredUnderAnotherKeyIsADuplicate(_ duplicates: DuplicateHandling) async throws {
            let harness = StoreHarness(policy: StorePolicy(duplicates: duplicates))
            try await harness.add("a", "/Users/me/A")
            let original = try await harness.add("b", "/Users/me/B")

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.regrant("b", with: harness.grant("/Users/me/A"))
            }

            guard case .duplicate(of: "a") = error else {
                Issue.record("Expected a duplicate of a, got \(String(describing: error))")
                return
            }
            #expect(try await harness.store.record("b") == original)
            #expect(harness.engine.isBalanced)
        }

        @Test func duplicatesCanBeAllowed() async throws {
            let harness = StoreHarness(policy: StorePolicy(duplicates: .allow))
            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")

            let record = try await harness.store.regrant("b", with: harness.grant("/Users/me/A"))

            #expect(record.lastKnownPath == "/Users/me/A")
        }

        @Test func theSameItemIsAcceptedByPathWhenItsIdentityCantBeRead() async throws {
            let harness = StoreHarness(policy: StorePolicy(requiresSameItemOnRegrant: true))
            let original = try await harness.add("a", "/Users/me/A")
            #expect(original.fileIdentity != nil)
            harness.engine.removeVolumeUUID(ofVolumeAt: "/")

            let record = try await harness.store.regrant("a", with: harness.grant("/Users/me/A"))

            #expect(record.lastKnownPath == "/Users/me/A")
            #expect(record.fileIdentity == original.fileIdentity)
        }

        @Test func aDifferentPathIsRefusedWhenTheIdentityCantBeRead() async throws {
            let harness = StoreHarness(policy: StorePolicy(requiresSameItemOnRegrant: true))
            try await harness.add("a", "/Users/me/A")
            harness.engine.removeVolumeUUID(ofVolumeAt: "/")

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.regrant("a", with: harness.grant("/Users/me/Other"))
            }

            guard case .differentItem("a") = error else {
                Issue.record("Expected a different item, got \(String(describing: error))")
                return
            }
            #expect(harness.engine.isBalanced)
        }
    }

    @Suite("File identities")
    struct Identities {
        @Test func itemsOnVolumesWithoutAUUIDHaveNoIdentity() async throws {
            let harness = StoreHarness()
            harness.engine.mountVolume(at: "/Volumes/Share")
            harness.engine.removeVolumeUUID(ofVolumeAt: "/Volumes/Share")

            let record = try await harness.add("a", "/Volumes/Share/A")

            #expect(record.fileIdentity == nil)
        }

        @Test func itemsOnVolumesWithoutAUUIDAreComparedByPath() async throws {
            let harness = StoreHarness()
            for share in ["/Volumes/One", "/Volumes/Two"] {
                harness.engine.mountVolume(at: share)
                harness.engine.removeVolumeUUID(ofVolumeAt: share)
            }
            try await harness.add("a", "/Volumes/One/A")

            try await harness.add("b", "/Volumes/Two/A")

            #expect(try await harness.store.keys() == ["a", "b"])
        }

        @Test func identitiesWithoutAVolumeUUIDDecodeAsUnknown() throws {
            let json = """
            {"key":"a","data":"AQ==","kind":"reference","lastKnownPath":"/A",
             "fileIdentity":{"fileID":9},"createdAt":"2024-01-01T00:00:00Z","metadata":{"name":"A"}}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let record = try decoder.decode(TestRecord.self, from: Data(json.utf8))

            #expect(record.fileIdentity == nil)
            #expect(record.lastKnownPath == "/A")
        }
    }

    @Suite("Implicit bookmarks")
    struct Implicit {
        func store(_ engine: FakeBookmarkEngine) -> TestStore {
            TestStore(persistence: InMemoryPersistence(), kind: .implicit, service: Fixtures.service(engine))
        }

        @Test(arguments: [SandboxEnvironment.Platform.macOS, .macCatalyst])
        func storesOnTheMacRefuseThem(_ platform: SandboxEnvironment.Platform) async throws {
            let engine = Fixtures.engine(SandboxEnvironment(platform: platform, isSandboxed: true))
            engine.addItem(at: "/Users/me/A")
            let store = store(engine)

            let error = await #expect(throws: TestStore.Failure.self) {
                try await store.add(engine.grant("/Users/me/A", origin: .openPanel), key: "a", metadata: Tag(name: "A"))
            }

            guard case .unsupported = error?.bookmarkFailure else {
                Issue.record("Expected an unsupported failure, got \(String(describing: error))")
                return
            }
            #expect(engine.calls.creations == 0)
            #expect(engine.isBalanced)
            #expect(try await store.keys().isEmpty)
        }

        @Test func storesOnIOSKeepThem() async throws {
            let engine = Fixtures.engine(Fixtures.iOS)
            engine.addItem(at: "/private/var/mobile/A")
            let store = store(engine)

            let record = try await store.add(engine.grant("/private/var/mobile/A", origin: .documentPicker), key: "a", metadata: Tag(name: "A"))

            #expect(record.kind == .implicit)
        }
    }

    @Suite("Covering leases")
    struct Covering {
        @Test(.timeLimit(.minutes(1)))
        func cancellationStopsTryingShallowerItems() async throws {
            let harness = StoreHarness()
            try await harness.add("outer", "/Users/me/A")
            try await harness.add("inner", "/Users/me/A/B")
            let gate = harness.engine.holdResolution(of: "/Users/me/A/B")
            let store = harness.store
            let requests = harness.engine.resolutionRequests.count

            let task = Task { try await store.lease(covering: URL(filePath: "/Users/me/A/B/file")) }
            await gate.waitUntilReached()
            task.cancel()
            let error = await #expect(throws: TestStore.Failure.self) { try await task.value }
            gate.open()

            #expect(error?.bookmarkFailure == .cancelled)
            #expect(harness.engine.resolutionRequests.dropFirst(requests).map(\.path) == ["/Users/me/A/B"])
        }

        @Test func aFailingDeeperItemFallsBackToAShallowerOne() async throws {
            let harness = StoreHarness()
            try await harness.add("outer", "/Users/me/A")
            try await harness.add("inner", "/Users/me/A/B")
            harness.engine.failResolution(of: "/Users/me/A/B", with: FakeErrors.corrupt, times: 1)

            let lease = try #require(try await harness.store.lease(covering: URL(filePath: "/Users/me/A/B/file")))

            #expect(lease.url.path(percentEncoded: false).hasPrefix("/Users/me/A"))
            #expect(harness.engine.isAccessing("/Users/me/A"))
            lease.end()
        }
    }

    @Suite("Shared resolutions")
    struct SharedResolutions {
        @Test(.timeLimit(.minutes(1)))
        func aSharedFailureIsRecordedOnce() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store
            let updates = harness.persistence.updateCount

            let tasks = (0..<3).map { _ in Task { try await store.lease("a") } }
            await gate.waitUntilReached()
            while await store.pendingResolutionCallers(for: "a") < 3 {
                await Task.yield()
            }
            gate.open()
            for task in tasks {
                _ = await task.result
            }

            #expect(harness.persistence.updateCount == updates + 1)
            #expect(harness.saved.first?.status.failure == .needsRegrant)
        }

        @Test(.timeLimit(.minutes(1)))
        func aFailureIsRecordedEvenWhenEveryCallerStoppedWaiting() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store

            let task = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            task.cancel()
            _ = await task.result
            gate.open()
            while try await store.record("a")?.status.failure == nil {
                await Task.yield()
            }

            #expect(try await store.record("a")?.status.failure == .needsRegrant)
        }

        @Test(.timeLimit(.minutes(1)))
        func callersThatStopWaitingAreNoLongerCounted() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store

            let cancelled = Task { try await store.lease("a") }
            let patient = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            while await store.pendingResolutionCallers(for: "a") < 2 {
                await Task.yield()
            }
            cancelled.cancel()
            _ = await cancelled.result

            #expect(await store.pendingResolutionCallers(for: "a") == 1)
            gate.open()
            try await patient.value.end()
            #expect(await store.pendingResolutionCallers(for: "a") == 0)
        }
    }

    @Suite("Documented behaviour")
    struct Documented {
        @Test func startingAccessHappensOnTheCallersThread() async throws {
            let engine = Fixtures.engine()
            let data = try await Fixtures.adoptFolder("/Users/me/A", engine: engine)
            let resolved = try await Fixtures.service(engine).resolve(data)
            let starts = engine.calls.starts

            let lease = resolved.beginAccess()

            #expect(engine.calls.starts == starts + 1)
            lease.end()
            #expect(engine.isBalanced)
        }

        @Test func mostRecentlyUsedAdditionsArriveAsAddedThenReordered() async throws {
            let harness = StoreHarness(policy: .recents(limit: 5))
            try await harness.add("a", "/Users/me/A")
            let updates = try await harness.store.updates()
            var iterator = updates.makeAsyncIterator()
            _ = await iterator.next()

            try await harness.add("b", "/Users/me/B")

            guard case .change(.added(let added)) = await iterator.next() else {
                Issue.record("Expected an addition")
                return
            }
            #expect(added.key == "b")
            #expect(await iterator.next() == .change(.reordered(["b", "a"])))
        }
    }
}
