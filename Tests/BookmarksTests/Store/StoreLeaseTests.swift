@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: leasing")
struct StoreLeaseTests {
    let harness = StoreHarness()

    @Test func leasesAStoredItem() async throws {
        try await harness.add("a", "/Users/me/A")

        let lease = try await harness.store.lease("a")

        #expect(lease.isActive)
        #expect(lease.url.path(percentEncoded: false) == "/Users/me/A/")
        #expect(harness.engine.isAccessing("/Users/me/A"))
        lease.end()
        #expect(harness.engine.isBalanced)
    }

    @Test func sharesActiveAccessWithoutResolvingAgain() async throws {
        try await harness.add("a", "/Users/me/A")
        let first = try await harness.store.lease("a")
        let resolutions = harness.engine.calls.resolutions
        let starts = harness.engine.calls.starts

        let second = try await harness.store.lease("a")

        #expect(harness.engine.calls.resolutions == resolutions)
        #expect(harness.engine.calls.starts == starts)
        #expect(second.url == first.url)
        first.end()
        second.end()
        #expect(harness.engine.isBalanced)
    }

    @Test func resolvesAgainOnceIdle() async throws {
        try await harness.add("a", "/Users/me/A")
        try await harness.store.lease("a").end()
        let resolutions = harness.engine.calls.resolutions

        try await harness.store.lease("a").end()

        #expect(harness.engine.calls.resolutions == resolutions + 1)
        #expect(harness.engine.isBalanced)
    }

    @Test func concurrentLeasesResolveAndStartOnce() async throws {
        try await harness.add("a", "/Users/me/A")
        let resolutions = harness.engine.calls.resolutions
        let starts = harness.engine.calls.starts
        let gate = harness.engine.holdResolution(of: "/Users/me/A")
        let store = harness.store

        let tasks = (0..<5).map { _ in Task { try await store.lease("a") } }
        await gate.waitUntilReached()
        while await store.pendingResolutionCallers(for: "a") < 5 {
            await Task.yield()
        }
        gate.open()
        var leases: [AccessLease] = []
        for task in tasks {
            leases.append(try await task.value)
        }

        #expect(harness.engine.calls.resolutions == resolutions + 1)
        #expect(harness.engine.calls.starts == starts + 1)
        leases.forEach { $0.end() }
        #expect(harness.engine.isBalanced)
    }

    @Test func unknownKeysAreNotFound() async {
        let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("nope") }

        guard case .notFound("nope") = error else {
            Issue.record("Expected notFound, got \(String(describing: error))")
            return
        }
    }

    @Test func updatesTheIdentityAfterAnAtomicReplace() async throws {
        harness.engine.addItem(at: "/Users/me/Notes.md", isDirectory: false)
        let record = try await harness.store.add(harness.engine.grant("/Users/me/Notes.md", origin: .openPanel), key: "notes", metadata: Tag(name: "n"))
        harness.engine.replaceItem(at: "/Users/me/Notes.md")

        try await harness.store.lease("notes").end()

        let updated = try #require(try await harness.store.record("notes"))
        #expect(updated.fileIdentity != record.fileIdentity)
        #expect(updated.fileIdentity == harness.engine.fileIdentity(of: URL(filePath: "/Users/me/Notes.md")))
    }

    @Suite("Stale refresh")
    struct Refresh {
        let harness = StoreHarness()

        @Test func persistsRefreshedBytesUnderTheSameKey() async throws {
            let original = try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Renamed")
            harness.clock.advance(by: 30)

            try await harness.store.lease("a").end()

            let record = try #require(try await harness.store.record("a"))
            #expect(record.data != original.data)
            #expect(record.lastKnownPath == "/Users/me/Renamed")
            #expect(record.refreshedAt == harness.clock.now)
            #expect(record.createdAt == original.createdAt)
            #expect(record.metadata == original.metadata)
            #expect(harness.saved.first?.data == record.data)
            #expect(harness.engine.isBalanced)
        }

        @Test func refreshedBytesResolveWithoutBeingStale() async throws {
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Renamed")
            try await harness.store.lease("a").end()
            let data = try #require(try await harness.store.record("a")?.data)

            let resolved = try await harness.store.service.resolve(data)

            #expect(!resolved.wasStale)
        }

        @Test func aFailedRefreshKeepsTheOriginalBytes() async throws {
            let original = try await harness.add("a", "/Users/me/A")
            harness.engine.reportStale("/Users/me/A")
            harness.engine.failCreation(of: "/Users/me/A", with: FakeErrors.denied)

            let lease = try await harness.store.lease("a")

            #expect(lease.isActive)
            #expect(try await harness.store.record("a")?.data == original.data)
            lease.end()
        }

        @Test func aFailedSaveOfRefreshedBytesStillGrantsAccess() async throws {
            let original = try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Renamed")
            harness.persistence.failSaves(1)

            let lease = try await harness.store.lease("a")

            #expect(lease.isActive)
            #expect(try await harness.store.record("a")?.data == original.data)
            lease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func publishesAnUpdate() async throws {
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Renamed")
            let changes = try await harness.store.updates()

            try await harness.store.lease("a").end()

            #expect(await collect(changes, count: 1) == ["updated a"])
        }

        @Test func unchangedRecordsAreNotSavedAgain() async throws {
            try await harness.add("a", "/Users/me/A")
            try await harness.store.lease("a").end()
            let saves = harness.persistence.saveCount

            try await harness.store.lease("a").end()

            #expect(harness.persistence.saveCount == saves)
        }
    }

    @Suite("Failures")
    struct Failures {
        @Test func failingRecordsAreKeptAndMarkedByDefault() async throws {
            let harness = StoreHarness()
            let original = try await harness.add("a", "/Users/me/A")
            harness.engine.removeItem(at: "/Users/me/A")

            let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

            #expect(error?.bookmarkFailure == .missing)
            let record = try #require(try await harness.store.record("a"))
            #expect(record.status == .unavailable(.missing, since: harness.clock.now))
            #expect(record.status.failure == .missing)
            #expect(record.data == original.data)
            #expect(harness.saved.first?.status == record.status)
        }

        @Test func repeatedFailuresKeepTheFirstDate() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.removeItem(at: "/Users/me/A")
            _ = try? await harness.store.lease("a")
            let firstFailure = harness.clock.now
            let saves = harness.persistence.saveCount
            harness.clock.advance(by: 100)

            _ = try? await harness.store.lease("a")

            #expect(try await harness.store.record("a")?.status == .unavailable(.missing, since: firstFailure))
            #expect(harness.persistence.saveCount == saves)
        }

        @Test func missingItemsCanBeDropped() async throws {
            let harness = StoreHarness(policy: StorePolicy(failureHandling: .dropMissing))
            try await harness.add("a", "/Users/me/A")
            harness.engine.removeItem(at: "/Users/me/A")
            let changes = try await harness.store.updates()

            _ = try? await harness.store.lease("a")

            #expect(try await harness.store.record("a") == nil)
            #expect(harness.saved.isEmpty)
            #expect(await collect(changes, count: 1) == ["removed a"])
        }

        @Test func dropMissingKeepsUnmountedVolumes() async throws {
            let harness = StoreHarness(policy: StorePolicy(failureHandling: .dropMissing))
            harness.engine.mountVolume(at: "/Volumes/Backup")
            try await harness.add("a", "/Volumes/Backup/Builds")
            harness.engine.unmountVolume(at: "/Volumes/Backup")

            _ = try? await harness.store.lease("a")

            #expect(try await harness.store.record("a")?.status.failure == .volumeUnavailable(name: "Backup"))
        }

        @Test func customDropRules() async throws {
            let harness = StoreHarness(policy: StorePolicy(failureHandling: FailureHandling { $0 == .needsRegrant }))
            try await harness.add("a", "/Users/me/A")
            harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)

            _ = try? await harness.store.lease("a")

            #expect(try await harness.store.record("a") == nil)
        }

        @Test func everyCallerSharingAFailedResolutionGetsTheFailure() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store
            let resolutions = harness.engine.calls.resolutions

            let tasks = (0..<3).map { _ in Task { try await store.lease("a") } }
            await gate.waitUntilReached()
            while await store.pendingResolutionCallers(for: "a") < 3 {
                await Task.yield()
            }
            gate.open()

            for task in tasks {
                let error = await #expect(throws: TestStore.Failure.self) { try await task.value }
                #expect(error?.bookmarkFailure == .needsRegrant)
            }
            #expect(harness.engine.calls.resolutions == resolutions + 1)
            #expect(await store.pendingResolutionCallers(for: "a") == 0)
        }

        @Test func aCancelledCallerStopsWaitingWhileOthersGetTheLease() async throws {
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

            let error = await #expect(throws: TestStore.Failure.self) { try await cancelled.value }
            #expect(error?.bookmarkFailure == .cancelled)
            gate.open()
            let lease = try await patient.value
            #expect(lease.isActive)
            lease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func cancellationDoesNotMarkRecords() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store

            let task = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            task.cancel()
            _ = try? await task.value
            gate.open()

            #expect(try await harness.store.record("a")?.status == .available)
        }

        @Test func unavailableRecordsRecoverWhenTheVolumeReturns() async throws {
            let harness = StoreHarness()
            harness.engine.mountVolume(at: "/Volumes/Backup")
            try await harness.add("a", "/Volumes/Backup/Builds")
            try await harness.add("b", "/Users/me/B")
            harness.engine.unmountVolume(at: "/Volumes/Backup")
            _ = try? await harness.store.lease("a")

            harness.engine.mountVolume(at: "/Volumes/Backup")
            let recovered = try await harness.store.refreshStatuses()

            #expect(recovered == ["a"])
            #expect(try await harness.store.record("a")?.status == .available)
        }
    }

    @Suite("Changes during resolution")
    struct Races {
        @Test func forgettingDuringResolutionWins() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store

            let task = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            try await harness.store.forget("a")
            gate.open()

            let error = await #expect(throws: TestStore.Failure.self) { try await task.value }
            guard case .notFound("a") = error else {
                Issue.record("Expected notFound, got \(String(describing: error))")
                return
            }
            #expect(try await harness.store.record("a") == nil)
            #expect(harness.store.activeLease(for: "a") == nil)
            #expect(harness.engine.isBalanced)
        }

        @Test func aRegrantDuringResolutionIsNotOverwrittenByARefresh() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Moved")
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store

            let task = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            let regranted = try await harness.store.regrant("a", with: harness.grant("/Users/me/New"))
            gate.open()
            let lease = try await task.value

            #expect(try await harness.store.record("a")?.data == regranted.data)
            #expect(lease.url.path(percentEncoded: false) == "/Users/me/New/")
            lease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func aLateCallerNeverJoinsAResolutionOfReplacedBytes() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            let gate = harness.engine.holdResolution(of: "/Users/me/A")
            let store = harness.store

            let early = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            try await store.regrant("a", with: harness.grant("/Users/me/New"))
            let lateLease = try await store.lease("a")
            gate.open()
            let earlyLease = try await early.value
            #expect(lateLease.url.path(percentEncoded: false) == "/Users/me/New/")
            #expect(earlyLease.url == lateLease.url)
            #expect(try await store.record("a")?.lastKnownPath == "/Users/me/New")
            earlyLease.end()
            lateLease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func givesUpWhenTheRecordKeepsChanging() async throws {
            let harness = StoreHarness()
            let store = harness.store
            try await harness.add("a", "/Users/me/0")
            var gate = harness.engine.holdResolution(of: "/Users/me/0")

            let task = Task { try await store.lease("a") }
            for next in 1...3 {
                await gate.waitUntilReached()
                try await store.regrant("a", with: harness.grant("/Users/me/\(next)"))
                let current = gate
                if next < 3 {
                    gate = harness.engine.holdResolution(of: "/Users/me/\(next)")
                }
                current.open()
            }

            let error = await #expect(throws: TestStore.Failure.self) { try await task.value }
            guard case .changedDuringAccess("a") = error else {
                Issue.record("Expected changedDuringAccess, got \(String(describing: error))")
                return
            }
            #expect(harness.engine.isBalanced)
        }
    }

    @Suite("withAccess")
    struct WithAccess {
        struct Failure: Error {}

        @Test func leasesEveryKeyOnceAndEndsThemAll() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")
            let engine = harness.engine

            let paths = try await harness.store.withAccess(to: ["a", "b", "a"]) { urls in
                #expect(engine.isAccessing("/Users/me/A"))
                #expect(engine.isAccessing("/Users/me/B"))
                return urls.mapValues { $0.path(percentEncoded: false) }
            }

            #expect(paths == ["a": "/Users/me/A/", "b": "/Users/me/B/"])
            #expect(harness.engine.isBalanced)
        }

        @Test func endsAcquiredLeasesWhenOneFails() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")
            try await harness.add("b", "/Users/me/B")
            harness.engine.removeItem(at: "/Users/me/B")

            await #expect(throws: TestStore.Failure.self) {
                try await harness.store.withAccess(to: ["a", "b"]) { _ in }
            }

            #expect(harness.engine.isBalanced)
        }

        @Test func endsLeasesWhenTheBodyThrows() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")

            await #expect(throws: Failure.self) {
                try await harness.store.withAccess(to: "a") { _ in throw Failure() }
            }

            #expect(harness.engine.isBalanced)
        }

        @Test func singleKeyVariantReturnsTheBodysValue() async throws {
            let harness = StoreHarness()
            try await harness.add("a", "/Users/me/A")

            let name = try await harness.store.withAccess(to: "a") { $0.lastPathComponent }

            #expect(name == "A")
        }
    }

    @Test func resolvesWithTheStoresMountingAndUIOptions() async throws {
        let harness = StoreHarness(policy: StorePolicy(mounting: .allowed, allowsUI: true))
        harness.engine.mountVolume(at: "/Volumes/Backup")
        try await harness.add("a", "/Volumes/Backup/Builds")
        harness.engine.unmountVolume(at: "/Volumes/Backup")

        let lease = try await harness.store.lease("a")

        let options = try #require(harness.engine.resolutionRequests.last?.options)
        #expect(!options.contains(.withoutMounting))
        #expect(!options.contains(.withoutUI))
        #expect(options.contains(.securityScope))
        #expect(harness.engine.containsItem(at: "/Volumes/Backup/Builds"))
        lease.end()
    }

    @Test func neverMountsOrShowsUIByDefault() async throws {
        let harness = StoreHarness()
        try await harness.add("a", "/Users/me/A")

        try await harness.store.lease("a").end()

        let options = try #require(harness.engine.resolutionRequests.last?.options)
        #expect(options.contains(.withoutMounting))
        #expect(options.contains(.withoutUI))
    }

    @Test func recentsMoveToTheFrontWhenAnActiveLeaseIsShared() async throws {
        let harness = StoreHarness(policy: .recents(limit: 5))
        try await harness.add("a", "/A")
        let held = try await harness.store.lease("a")
        try await harness.add("b", "/B")

        let shared = try await harness.store.lease("a")

        #expect(try await harness.store.keys() == ["a", "b"])
        held.end()
        shared.end()
    }

    @Test func leasesUnsandboxedReferenceBookmarks() async throws {
        let harness = StoreHarness(environment: Fixtures.unsandboxedMac)
        try await harness.add("a", "/Users/me/A")

        let lease = try await harness.store.lease("a")

        #expect(try await harness.store.record("a")?.kind == .reference)
        #expect(lease.url.path(percentEncoded: false) == "/Users/me/A/")
        lease.end()
        #expect(harness.engine.isBalanced)
    }

    @Suite("Covering leases")
    struct Covering {
        @Test func ignoresCaseOnVolumesThatIgnoreIt() async throws {
            let harness = StoreHarness()
            harness.engine.makeCaseInsensitive()
            try await harness.add("projects", "/Users/me/Projects")

            let lease = try #require(try await harness.store.lease(covering: URL(filePath: "/users/me/projects/App/File.swift")))

            #expect(lease.url.path(percentEncoded: false) == "/Users/me/Projects/")
            #expect(lease.url(forDescendant: URL(filePath: "/users/me/projects/App/File.swift"))?.path(percentEncoded: false) == "/Users/me/Projects/App/File.swift")
            #expect(harness.store.registry.lease(covering: URL(filePath: "/USERS/ME/PROJECTS/App"))?.url == lease.url)
            lease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func reusesAFolderAnotherStoreHolds() async throws {
            let engine = Fixtures.engine()
            let service = Fixtures.service(engine)
            let folders = TestStore(persistence: InMemoryPersistence(), service: service)
            let files = TestStore(persistence: InMemoryPersistence(), service: service)
            engine.addItem(at: "/Users/me/Projects")
            try await folders.add(engine.grant("/Users/me/Projects", origin: .openPanel), key: "projects", metadata: Tag(name: "p"))
            let folder = try await folders.lease("projects")
            let starts = engine.calls.starts

            let covering = try #require(try await files.lease(covering: URL(filePath: "/Users/me/Projects/App/File.swift")))

            #expect(covering.url == folder.url)
            #expect(engine.calls.starts == starts)
            #expect(service.ledger.startedScopeCount == 1)
            covering.end()
            folder.end()
            #expect(engine.isBalanced)
        }

        @Test func respectsCaseOnCaseSensitiveVolumes() async throws {
            let harness = StoreHarness()
            try await harness.add("projects", "/Users/me/Projects")

            #expect(try await harness.store.lease(covering: URL(filePath: "/users/me/projects/App")) == nil)
            #expect(try await harness.store.key(matching: URL(filePath: "/users/me/projects")) == nil)
        }

        @Test func fallsBackToAShallowerItemWhenTheDeepestFails() async throws {
            let harness = StoreHarness(policy: StorePolicy(validators: []))
            try await harness.add("home", "/Users/me")
            try await harness.add("projects", "/Users/me/Projects")
            harness.engine.failResolution(of: "/Users/me/Projects", with: FakeErrors.corrupt)

            let lease = try #require(try await harness.store.lease(covering: URL(filePath: "/Users/me/Projects/App")))

            #expect(lease.url.path(percentEncoded: false) == "/Users/me/")
            #expect(try await harness.store.record("projects")?.status.failure == .needsRegrant)
            lease.end()
            #expect(harness.engine.isBalanced)
        }

        @Test func throwsTheDeepestFailureWhenNothingResolves() async throws {
            let harness = StoreHarness(policy: StorePolicy(validators: []))
            try await harness.add("home", "/Users/me")
            try await harness.add("projects", "/Users/me/Projects")
            harness.engine.failResolution(of: "/Users/me", with: FakeErrors.denied)
            harness.engine.removeItem(at: "/Users/me/Projects")

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.lease(covering: URL(filePath: "/Users/me/Projects/App"))
            }

            #expect(error?.bookmarkFailure == .missing)
        }
    }

    @Test func endAllAccessStopsEverything() async throws {
        try await harness.add("a", "/Users/me/A")
        try await harness.add("b", "/Users/me/B")
        let a = try await harness.store.lease("a")
        let b = try await harness.store.lease("b")

        harness.store.endAllAccess()

        #expect(!a.isActive && !b.isActive)
        #expect(harness.engine.isBalanced)
        #expect(harness.store.activeLease(for: "a") == nil)
    }

    @Test func concurrentLeasesOfAStaleBookmarkRefreshOnce() async throws {
        try await harness.add("a", "/Users/me/A")
        harness.engine.moveItem(from: "/Users/me/A", to: "/Users/me/Renamed")
        let calls = harness.engine.calls
        let saves = harness.persistence.saveCount
        let gate = harness.engine.holdResolution(of: "/Users/me/A")
        let store = harness.store

        let tasks = (0..<5).map { _ in Task { try await store.lease("a") } }
        await gate.waitUntilReached()
        while await store.pendingResolutionCallers(for: "a") < 5 {
            await Task.yield()
        }
        gate.open()
        var leases: [AccessLease] = []
        for task in tasks {
            leases.append(try await task.value)
        }

        #expect(harness.engine.calls.resolutions == calls.resolutions + 1)
        #expect(harness.engine.calls.creations == calls.creations + 1)
        #expect(harness.persistence.saveCount == saves + 1)
        #expect(Set(leases.map(\.url)).count == 1)
        leases.forEach { $0.end() }
        #expect(harness.engine.isBalanced)
    }

    @Test func addingOverALeasedKeyDetachesItsLease() async throws {
        try await harness.add("a", "/Users/me/A")
        let lease = try await harness.store.lease("a")

        try await harness.add("a", "/Users/me/B")

        #expect(harness.store.activeLease(for: "a") == nil)
        #expect(lease.isActive)
        let fresh = try await harness.store.lease("a")
        #expect(fresh.url.path(percentEncoded: false) == "/Users/me/B/")
        lease.end()
        fresh.end()
        #expect(harness.engine.isBalanced)
    }
}
