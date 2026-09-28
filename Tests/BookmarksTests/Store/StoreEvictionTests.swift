@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: eviction")
struct StoreEvictionTests {
    /// A document history: gone files first, then the least recently used, never a pinned file
    /// that still exists.
    static let history = StorePolicy(limit: 3, eviction: .goneFirst, recordsLastUse: true)

    /// Adds records `keys` one second apart, so each is used after the one before.
    static func fill(_ harness: StoreHarness, _ keys: [String]) async throws {
        for key in keys {
            try await harness.add(key, "/Users/me/\(key)")
            harness.clock.advance(by: 1)
        }
    }

    @Suite("Gone first")
    struct GoneFirst {
        let harness = StoreHarness(policy: StoreEvictionTests.history)

        @Test func evictsGoneItemsBeforeRecentOnes() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            harness.engine.removeItem(at: "/Users/me/c")
            _ = try? await harness.store.lease("c")

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys() == ["a", "b", "d"])
        }

        @Test func itemsInTheTrashAreGone() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            harness.engine.moveItem(from: "/Users/me/c", to: "/Users/me/.Trash/c")
            try await harness.store.lease("c").end()
            #expect(try await harness.store.record("c")?.isInTrash == true)

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys() == ["a", "b", "d"])
        }

        @Test func thenTheLeastRecentlyUsed() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            try await harness.store.lease("a").end()

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys() == ["a", "c", "d"])
        }

        @Test func pinnedItemsStayWhileTheyExist() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            try await harness.store.setPinned(true, for: "a")
            try await harness.store.setPinned(true, for: "b")

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys() == ["a", "b", "d"])
        }

        @Test func pinnedItemsThatAreGoneGo() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            try await harness.store.setPinned(true, for: "a")
            harness.engine.removeItem(at: "/Users/me/a")
            _ = try? await harness.store.lease("a")

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys() == ["b", "c", "d"])
        }

        @Test func unmountedVolumesAndLostAccessArentGone() async throws {
            harness.engine.mountVolume(at: "/Volumes/Backup")
            try await harness.add("volume", "/Volumes/Backup/a")
            harness.clock.advance(by: 1)
            try await harness.add("regrant", "/Users/me/regrant")
            harness.clock.advance(by: 1)
            try await harness.add("recent", "/Users/me/recent")
            harness.engine.unmountVolume(at: "/Volumes/Backup")
            harness.engine.failResolution(of: "/Users/me/regrant", with: FakeErrors.corrupt)
            _ = try? await harness.store.lease("volume")
            _ = try? await harness.store.lease("regrant")
            try await harness.store.setPinned(true, for: "volume")
            try await harness.store.setPinned(true, for: "regrant")

            try await harness.add("new", "/Users/me/new")

            #expect(try await harness.store.keys() == ["volume", "regrant", "new"])
        }

        @Test func aStoreWhoseRecordsAreAllProtectedGrows() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            for key in ["a", "b", "c"] {
                try await harness.store.setPinned(true, for: key)
            }

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys().count == 4)
        }

        @Test func pathOnlyRecordsThatAreMissingAreGone() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b"])
            _ = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/lost"), key: "lost", metadata: Tag(name: "lost"))
            harness.engine.makeAccessibleWithoutGrant("/Users/me")
            _ = try? await harness.store.lease("lost")
            #expect(try await harness.store.record("lost")?.isGone == true)

            try await harness.add("d", "/Users/me/d")

            #expect(try await harness.store.keys() == ["a", "b", "d"])
        }

        @Test func refreshingEveryStatusFindsDeletedItems() async throws {
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            harness.engine.removeItem(at: "/Users/me/c")
            #expect(try await harness.store.record("c")?.status == .available)

            let resolved = try await harness.store.refreshStatuses(includingAvailable: true)
            try await harness.add("d", "/Users/me/d")

            #expect(resolved == ["a", "b"])
            #expect(try await harness.store.keys() == ["a", "b", "d"])
        }
    }

    @Suite("Other policies")
    struct OtherPolicies {
        @Test func storeOrderIsTheDefaultAndKeepsPinnedRecords() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 2))
            try await harness.add("a", "/Users/me/a")
            try await harness.add("b", "/Users/me/b")
            try await harness.store.setPinned(true, for: "a")

            try await harness.add("c", "/Users/me/c")

            #expect(try await harness.store.keys() == ["a", "c"])
        }

        @Test func leastRecentlyUsedFollowsUseNotOrder() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 2, eviction: .leastRecentlyUsed))
            try await StoreEvictionTests.fill(harness, ["a", "b"])
            try await harness.store.markUsed("a")

            try await harness.add("c", "/Users/me/c")

            #expect(try await harness.store.keys() == ["a", "c"])
        }

        @Test func aCustomPolicyDecides() async throws {
            let byName = EvictionPolicy(protects: { $0.lastKnownPath.hasSuffix("/keep") }) { $0.lastKnownPath > $1.lastKnownPath }
            let harness = StoreHarness(policy: StorePolicy(limit: 2, eviction: byName))
            try await harness.add("keep", "/Users/me/keep")
            try await harness.add("x", "/Users/me/x")

            try await harness.add("y", "/Users/me/y")

            #expect(try await harness.store.keys() == ["keep", "y"])
        }
    }

    @Suite("Reporting")
    struct Reporting {
        @Test func reportsRecordsEvictedBeyondTheLimit() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 1))
            let evictions = harness.store.evictions()
            try await harness.add("a", "/Users/me/a", name: "First")

            try await harness.add("b", "/Users/me/b")

            var iterator = evictions.makeAsyncIterator()
            let eviction = try #require(await iterator.next())
            #expect(eviction.key == "a")
            #expect(eviction.reason == .limit)
            #expect(eviction.record.metadata == Tag(name: "First"))
        }

        @Test func reportsRecordsDroppedForAFailure() async throws {
            let harness = StoreHarness(policy: StorePolicy(failureHandling: .dropMissing))
            let evictions = harness.store.evictions()
            try await harness.add("a", "/Users/me/a")
            harness.engine.removeItem(at: "/Users/me/a")

            _ = try? await harness.store.lease("a")

            var iterator = evictions.makeAsyncIterator()
            let eviction = try #require(await iterator.next())
            #expect(eviction.key == "a")
            #expect(eviction.reason == .failure(.missing))
            #expect(try await harness.store.records().isEmpty)
        }

        @Test func forgettingIsntAnEviction() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 1))
            let evictions = harness.store.evictions(bufferingPolicy: .bufferingNewest(4))
            try await harness.add("a", "/Users/me/a")
            try await harness.store.forget("a")
            try await harness.add("b", "/Users/me/b")

            try await harness.add("c", "/Users/me/c")

            var iterator = evictions.makeAsyncIterator()
            #expect(await iterator.next()?.key == "b")
        }

        @Test func everySubscriberHearsEveryEviction() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 1))
            let first = harness.store.evictions()
            let second = harness.store.evictions()
            try await harness.add("a", "/Users/me/a")

            try await harness.add("b", "/Users/me/b")

            var one = first.makeAsyncIterator()
            var two = second.makeAsyncIterator()
            #expect(await one.next()?.key == "a")
            #expect(await two.next()?.key == "a")
        }

        @Test func aFailedSaveReportsNothing() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 1))
            try await harness.add("a", "/Users/me/a")
            let evictions = harness.store.evictions()
            harness.persistence.failSaves(1)

            await #expect(throws: TestStore.Failure.self) { try await harness.add("b", "/Users/me/b") }
            try await harness.add("c", "/Users/me/c")

            var iterator = evictions.makeAsyncIterator()
            let eviction = await iterator.next()
            #expect(eviction?.key == "a")
            #expect(try await harness.store.keys() == ["c"])
        }

        @Test func streamsEndWithTheStore() async throws {
            var store: TestStore? = TestStore(persistence: InMemoryPersistence(), service: Fixtures.service(Fixtures.engine()))
            let evictions = try #require(store).evictions()

            store = nil

            for await _ in evictions {
                Issue.record("A store that's gone reported an eviction")
            }
        }

        @Test func stoppingToListenUnsubscribes() async throws {
            let harness = StoreHarness(policy: StorePolicy(limit: 1))
            let listening = Task {
                for await _ in harness.store.evictions() {}
            }
            await Task.yield()
            listening.cancel()
            await listening.value

            try await harness.add("a", "/Users/me/a")
            try await harness.add("b", "/Users/me/b")

            #expect(try await harness.store.keys() == ["b"])
        }
    }

    @Suite("Use and pinning")
    struct UseAndPinning {
        @Test func addingAndRegrantingRecordUse() async throws {
            let harness = StoreHarness()
            let added = try await harness.add("a", "/Users/me/a")
            harness.clock.advance(by: 60)

            let regranted = try await harness.store.regrant("a", with: harness.grant("/Users/me/a"))

            #expect(added.lastUsedAt == added.createdAt)
            #expect(regranted.lastUsedAt == harness.clock.now)
        }

        @Test func leasesRecordUseWhenThePolicyAsks() async throws {
            let harness = StoreHarness(policy: StorePolicy(recordsLastUse: true))
            try await harness.add("a", "/Users/me/a")
            harness.clock.advance(by: 60)

            try await harness.store.lease("a").end()

            #expect(try await harness.store.record("a")?.lastUsedAt == harness.clock.now)
            #expect(harness.saved.first?.lastUsedAt == harness.clock.now)
        }

        @Test func leasesDontWriteOtherwise() async throws {
            let harness = StoreHarness()
            let added = try await harness.add("a", "/Users/me/a")
            try await harness.store.lease("a").end()
            let saves = harness.persistence.saveCount
            harness.clock.advance(by: 60)

            try await harness.store.lease("a").end()

            #expect(harness.persistence.saveCount == saves)
            #expect(try await harness.store.record("a")?.lastUsedAt == added.lastUsedAt)
        }

        @Test func sharedLeasesRecordUseToo() async throws {
            let harness = StoreHarness(policy: StorePolicy(recordsLastUse: true))
            try await harness.add("a", "/Users/me/a")
            let first = try await harness.store.lease("a")
            harness.clock.advance(by: 60)

            let second = try await harness.store.lease("a")

            #expect(try await harness.store.record("a")?.lastUsedAt == harness.clock.now)
            first.end()
            second.end()
        }

        @Test func markingUseMovesARecentsListToo() async throws {
            let harness = StoreHarness(policy: .recents(limit: 5))
            try await harness.add("a", "/Users/me/a")
            try await harness.add("b", "/Users/me/b")
            harness.clock.advance(by: 5)

            try await harness.store.markUsed("a")

            #expect(try await harness.store.keys() == ["a", "b"])
            #expect(try await harness.store.record("a")?.lastUsedAt == harness.clock.now)
        }

        @Test func markingAnUnknownKeyFails() async {
            await #expect(throws: TestStore.Failure.self) { try await StoreHarness().store.markUsed("nope") }
        }

        @Test func pinningIsSavedAndReported() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/a")
            let changes = try await harness.store.updates()

            try await harness.store.setPinned(true, for: "a")
            try await harness.store.setPinned(true, for: "a")

            #expect(harness.saved.first?.isPinned == true)
            #expect(await collect(changes, count: 1) == ["updated a"])
            try await harness.store.setPinned(false, for: "a")
            #expect(harness.saved.first?.isPinned == false)
        }

        @Test func pinningAnUnknownKeyFails() async {
            await #expect(throws: TestStore.Failure.self) { try await StoreHarness().store.setPinned(true, for: "nope") }
        }

        @Test func reAddingAKeyKeepsItsPin() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/a")
            try await harness.store.setPinned(true, for: "a")

            let replaced = try await harness.add("a", "/Users/me/other")

            #expect(replaced.isPinned)
        }
    }

    @Suite("Forgetting by predicate")
    struct ForgettingWhere {
        @Test func removesMatchingRecordsInOneSave() async throws {
            let harness = StoreHarness()
            try await StoreEvictionTests.fill(harness, ["a", "b", "c"])
            harness.engine.removeItem(at: "/Users/me/a")
            harness.engine.removeItem(at: "/Users/me/c")
            try await harness.store.refreshStatuses(includingAvailable: true)
            let saves = harness.persistence.saveCount

            let removed = try await harness.store.forget { $0.isGone }

            #expect(removed == ["a", "c"])
            #expect(try await harness.store.keys() == ["b"])
            #expect(harness.persistence.saveCount == saves + 1)
        }

        @Test func removingNothingSavesNothing() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/a")
            let saves = harness.persistence.saveCount

            #expect(try await harness.store.forget { _ in false }.isEmpty)
            #expect(harness.persistence.saveCount == saves)
        }
    }
}

@Suite("EvictionPolicy")
struct EvictionPolicyTests {
    static let date = Date(timeIntervalSince1970: 1_000)

    static func candidate(
        _ position: Int,
        status: RecordStatus = .available,
        path: String = "/Users/me/file",
        usedAt: Date? = nil,
        isPinned: Bool = false,
        ordering: RecordOrdering = .insertion
    ) -> EvictionCandidate {
        EvictionCandidate(
            status: status,
            lastKnownPath: path,
            createdAt: date,
            lastUsedAt: usedAt,
            isPinned: isPinned,
            position: position,
            ordering: ordering
        )
    }

    @Test(arguments: [
        ("/Users/me/.Trash/file", true),
        ("/Volumes/Disk/.Trashes/501/file", true),
        ("/Users/me/Trash/file", false),
        ("/Users/me/.Trashy", false),
    ])
    func findsItemsInATrash(_ path: String, _ inTrash: Bool) {
        #expect(Self.candidate(0, path: path).isInTrash == inTrash)
        #expect(Self.candidate(0, path: path).isGone == inTrash)
    }

    @Test(arguments: [
        (BookmarkFailure.missing, true),
        (.corrupt, true),
        (.volumeUnavailable(name: nil), false),
        (.needsRegrant, false),
        (.denied, false),
        (.timedOut, false),
    ])
    func goneMeansMissingOrCorrupt(_ failure: BookmarkFailure, _ gone: Bool) {
        let candidate = Self.candidate(0, status: .unavailable(failure, since: Self.date))

        #expect(candidate.isGone == gone)
    }

    @Test func lastUseFallsBackToCreation() {
        #expect(Self.candidate(0).lastUse == Self.date)
        #expect(Self.candidate(0, usedAt: Self.date.addingTimeInterval(5)).lastUse == Self.date.addingTimeInterval(5))
    }

    @Test func storeOrderDependsOnTheOrdering() {
        #expect(Self.candidate(0).isLessRecentInStoreOrder(than: Self.candidate(1)))
        #expect(Self.candidate(1, ordering: .mostRecentlyUsed).isLessRecentInStoreOrder(than: Self.candidate(0, ordering: .mostRecentlyUsed)))
    }

    @Test func protectedCandidatesAreLeftOut() {
        let candidates = [Self.candidate(0, isPinned: true), Self.candidate(1), Self.candidate(2, status: .unavailable(.missing, since: Self.date), isPinned: true)]

        #expect(EvictionPolicy.storeOrder.evictionOrder(of: candidates) == [1, 2])
        #expect(EvictionPolicy.goneFirst.evictionOrder(of: candidates) == [2, 1])
        #expect(EvictionPolicy.storeOrder.isProtected(candidates[0]))
        #expect(!EvictionPolicy.storeOrder.isProtected(candidates[2]))
    }

    @Test func tiesGoInStoreOrder() {
        let candidates = (0..<3).map { Self.candidate($0, ordering: .mostRecentlyUsed) }

        #expect(EvictionPolicy.leastRecentlyUsed.evictionOrder(of: candidates) == [2, 1, 0])
        #expect(EvictionPolicy.goneFirst.evictionOrder(of: candidates) == [2, 1, 0])
    }

    @Test func goneFirstThenLeastRecentlyUsed() {
        let candidates = [
            Self.candidate(0, usedAt: Self.date.addingTimeInterval(30)),
            Self.candidate(1, path: "/Users/me/.Trash/x", usedAt: Self.date.addingTimeInterval(50)),
            Self.candidate(2, usedAt: Self.date.addingTimeInterval(10)),
            Self.candidate(3, status: .unavailable(.corrupt, since: Self.date), usedAt: Self.date.addingTimeInterval(40)),
        ]

        #expect(EvictionPolicy.goneFirst.evictionOrder(of: candidates) == [3, 1, 2, 0])
    }

    @Test func candidatesDescribeRecords() {
        let record = BookmarkRecord(
            key: "a",
            data: BookmarkData(Data()),
            kind: .reference,
            lastKnownPath: "/a",
            status: .available,
            createdAt: Self.date,
            lastUsedAt: Self.date.addingTimeInterval(1),
            isPinned: true,
            metadata: NoMetadata()
        )

        let candidate = EvictionCandidate(record, position: 3, ordering: .mostRecentlyUsed)

        #expect(candidate == EvictionCandidate(
            status: .available,
            lastKnownPath: "/a",
            createdAt: Self.date,
            lastUsedAt: Self.date.addingTimeInterval(1),
            isPinned: true,
            hasBookmark: false,
            position: 3,
            ordering: .mostRecentlyUsed
        ))
    }
}
