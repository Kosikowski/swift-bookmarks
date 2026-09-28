@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: path-only records")
struct StorePathOnlyTests {
    let harness = StoreHarness()

    func addPathOnly(_ key: String, _ path: String, exists: Bool = true) async throws -> TestRecord {
        if exists {
            harness.engine.addItem(at: path)
        }
        return try await harness.store.add(pathOnly: URL(filePath: path), key: key, metadata: Tag(name: key))
    }

    @Suite("Adding")
    struct Adding {
        let harness = StoreHarness()

        @Test func storesThePathWithoutABookmark() async throws {
            harness.engine.addItem(at: "/Users/me/Notes.md", isDirectory: false)
            let identity = harness.engine.fileIdentity(of: URL(filePath: "/Users/me/Notes.md"))

            let record = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/./Notes.md"), key: "a", metadata: Tag(name: "a"))

            #expect(!record.hasBookmark)
            #expect(record.data.isEmpty)
            #expect(record.kind == .appScoped(.readWrite))
            #expect(record.lastKnownPath == "/Users/me/Notes.md")
            #expect(record.fileIdentity == identity)
            #expect(record.status == .unknown)
            #expect(record.lastUsedAt == harness.clock.now)
            #expect(record.createdAt == harness.clock.now)
            #expect(harness.saved == [record])
            #expect(harness.engine.calls.creations == 0)
            #expect(harness.engine.calls.starts == 0)
        }

        @Test func anItemThatIsntThereHasNoIdentity() async throws {
            let record = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/Gone.md"), key: "a", metadata: Tag(name: "a"))

            #expect(record.fileIdentity == nil)
            #expect(record.lastKnownPath == "/Users/me/Gone.md")
        }

        @Test func duplicatesAreFoundByIdentity() async throws {
            try await harness.add("a", "/Users/me/A")

            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "b", metadata: Tag(name: "b"))
            }

            guard case .duplicate(of: "a") = error else {
                Issue.record("Expected a duplicate, got \(String(describing: error))")
                return
            }
        }

        @Test func duplicatesWithoutAnIdentityAreFoundByPath() async throws {
            _ = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/Gone"), key: "a", metadata: Tag(name: "a"))

            await #expect(throws: TestStore.Failure.self) {
                try await harness.store.add(pathOnly: URL(filePath: "/Users/me/Gone/"), key: "b", metadata: Tag(name: "b"))
            }
        }

        @Test func returningExistingKeepsTheBookmarkOfTheExistingRecord() async throws {
            let harness = StoreHarness(policy: StorePolicy(duplicates: .returnExisting))
            let original = try await harness.add("a", "/Users/me/A")

            let returned = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "b", metadata: Tag(name: "b"))

            #expect(returned.key == "a")
            #expect(try await harness.store.keys() == ["a"])
            #expect(returned.data == original.data, "a path says nothing new about a bookmarked item")
            #expect(returned.lastUsedAt == harness.clock.now)
        }

        @Test func returningExistingGivesAPathOnlyRecordTheNewBookmark() async throws {
            let harness = StoreHarness(policy: StorePolicy(duplicates: .returnExisting))
            harness.engine.addItem(at: "/Users/me/A")
            _ = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "a", metadata: Tag(name: "a"))

            let returned = try await harness.add("b", "/Users/me/A")

            #expect(returned.key == "a")
            #expect(returned.hasBookmark)
        }

        @Test func implicitStoresOnMacOSRefusePathOnlyRecords() async {
            let engine = Fixtures.engine()
            let store = TestStore(persistence: InMemoryPersistence(), kind: .implicit, service: Fixtures.service(engine))

            let error = await #expect(throws: TestStore.Failure.self) {
                try await store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "a", metadata: Tag(name: "a"))
            }

            guard case .unsupported? = error?.bookmarkFailure else {
                Issue.record("Expected unsupported, got \(String(describing: error))")
                return
            }
        }

        @Test func conveniencesForIdentifiersAndNoMetadata() async throws {
            let engine = Fixtures.engine()
            let service = Fixtures.service(engine)
            let byID = BookmarkStore<BookmarkID, Tag>(persistence: InMemoryPersistence(), service: service)
            let plain = BookmarkStore<String, NoMetadata>(persistence: InMemoryPersistence(), service: service)
            let both = BookmarkStore<BookmarkID, NoMetadata>(persistence: InMemoryPersistence(), service: service)

            let first = try await byID.add(pathOnly: URL(filePath: "/a"), metadata: Tag(name: "a"))
            let second = try await plain.add(pathOnly: URL(filePath: "/b"), key: "b")
            let third = try await both.add(pathOnly: URL(filePath: "/c"))

            #expect(!first.hasBookmark && !second.hasBookmark && !third.hasBookmark)
            #expect(second.key == "b")
            engine.addItem(at: "/d")
            let (record, lease) = try await plain.addAndLease(engine.grant("/d", origin: .openPanel), key: "d")
            #expect(record.hasBookmark && lease.isActive)
            lease.end()
            #expect(engine.isBalanced)
        }
    }

    @Suite("Getting a bookmark")
    struct Upgrading {
        let base = StorePathOnlyTests()
        var harness: StoreHarness { base.harness }

        @Test func aLeaseMakesTheBookmarkWhenTheAppReachesTheItem() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Folder")
            harness.engine.makeAccessibleWithoutGrant("/Users/me/Folder")
            harness.clock.advance(by: 10)
            let changes = try await harness.store.updates()

            let lease = try await harness.store.lease("a")
            let record = try #require(try await harness.store.record("a"))

            #expect(lease.url.path(percentEncoded: false) == "/Users/me/Folder/")
            #expect(record.hasBookmark)
            #expect(record.kind == .appScoped(.readWrite))
            #expect(record.status == .available)
            #expect(record.refreshedAt == harness.clock.now)
            #expect(record.fileIdentity == harness.engine.fileIdentity(of: URL(filePath: "/Users/me/Folder")))
            #expect(harness.saved.first?.data == record.data)
            #expect(harness.engine.calls.creations == 1)
            #expect(await collect(changes, count: 1) == ["updated a"])
            lease.end()
            #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")

            // Later leases resolve the bookmark it made.
            harness.engine.moveItem(from: "/Users/me/Folder", to: "/Users/me/Moved")
            try await harness.store.withAccess(to: "a") { url in
                #expect(url.path(percentEncoded: false) == "/Users/me/Moved/")
            }
            #expect(harness.engine.calls.creations == 2, "one for the path, one to refresh the stale bookmark")
        }

        @Test func aFolderTheAppHoldsIsEnough() async throws {
            try await harness.add("folder", "/Users/me/Projects")
            _ = try await base.addPathOnly("file", "/Users/me/Projects/App.json")
            let folder = try await harness.store.lease("folder")

            let file = try await harness.store.lease("file")
            folder.end()
            file.end()

            #expect(try await harness.store.record("file")?.hasBookmark == true)
            #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
        }

        @Test func withoutAccessTheLeaseFailsAndTheRecordStays() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Private")

            let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

            #expect(error?.bookmarkFailure == .denied)
            let record = try #require(try await harness.store.record("a"))
            #expect(!record.hasBookmark)
            #expect(record.status.failure == .denied)
            #expect(record.lastKnownPath == "/Users/me/Private")
            #expect(harness.engine.isBalanced)
        }

        @Test func aMissingItemIsMissing() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Gone", exists: false)
            harness.engine.makeAccessibleWithoutGrant("/Users/me")

            let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

            #expect(error?.bookmarkFailure == .missing)
            #expect(try await harness.store.record("a")?.isGone == true)
        }

        @Test func anItemOnAnUnmountedVolumeIsUnavailableNotMissing() async throws {
            harness.engine.mountVolume(at: "/Volumes/Backup")
            _ = try await base.addPathOnly("a", "/Volumes/Backup/Builds")
            harness.engine.makeAccessibleWithoutGrant("/Volumes/Backup")
            harness.engine.unmountVolume(at: "/Volumes/Backup")

            let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

            #expect(error?.bookmarkFailure == .volumeUnavailable(name: "Backup"))
            #expect(try await harness.store.record("a")?.isGone == false)
        }

        @Test func concurrentLeasesMakeOneBookmark() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Folder")
            harness.engine.makeAccessibleWithoutGrant("/Users/me/Folder")
            let gate = harness.engine.holdCreation(of: "/Users/me/Folder")
            let store = harness.store

            let first = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            let second = Task { try await store.lease("a") }
            while await store.pendingResolutionCallers(for: "a") < 2 {
                await Task.yield()
            }
            gate.open()
            let leases = try await [first.value, second.value]

            #expect(harness.engine.calls.creations == 1)
            leases.forEach { $0.end() }
            #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
        }

        @Test func aNewPathDuringTheUpgradeWins() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Old")
            harness.engine.addItem(at: "/Users/me/New")
            harness.engine.makeAccessibleWithoutGrant("/Users/me")
            let gate = harness.engine.holdCreation(of: "/Users/me/Old")
            let store = harness.store

            let leasing = Task { try await store.lease("a") }
            await gate.waitUntilReached()
            try await store.updateLastKnownPath("a", to: URL(filePath: "/Users/me/New"))
            gate.open()
            let lease = try await leasing.value

            #expect(lease.url.path(percentEncoded: false) == "/Users/me/New/")
            #expect(try await store.record("a")?.lastKnownPath == "/Users/me/New")
            lease.end()
            #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
        }

        @Test func refreshingStatusesMakesBookmarksWherePossible() async throws {
            _ = try await base.addPathOnly("reachable", "/Container/Reachable")
            _ = try await base.addPathOnly("private", "/Users/me/Private")
            harness.engine.makeAccessibleWithoutGrant("/Container")

            let resolved = try await harness.store.refreshStatuses()

            #expect(resolved == ["reachable"])
            #expect(try await harness.store.record("reachable")?.hasBookmark == true)
            #expect(try await harness.store.record("private")?.status.failure == .denied)
            #expect(harness.engine.isBalanced)
        }

        @Test func aRegrantGivesTheRecordItsBookmark() async throws {
            let original = try await base.addPathOnly("a", "/Users/me/A")
            harness.clock.advance(by: 5)

            let record = try await harness.store.regrant("a", with: harness.engine.grant("/Users/me/A", origin: .openPanel))

            #expect(record.hasBookmark)
            #expect(record.status == .available)
            #expect(record.createdAt == original.createdAt)
            #expect(record.lastUsedAt == harness.clock.now)
            #expect(harness.engine.isBalanced)
        }

        @Test func aRegrantThatMustMatchComparesTheIdentity() async throws {
            let harness = StoreHarness(policy: StorePolicy(requiresSameItemOnRegrant: true))
            harness.engine.addItem(at: "/Users/me/A")
            harness.engine.addItem(at: "/Users/me/B")
            _ = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "a", metadata: Tag(name: "a"))

            await #expect(throws: TestStore.Failure.self) {
                try await harness.store.regrant("a", with: harness.engine.grant("/Users/me/B", origin: .openPanel))
            }
            try await harness.store.regrant("a", with: harness.engine.grant("/Users/me/A", origin: .openPanel))
        }

        @Test func coveringLeasesConsiderPathOnlyRecords() async throws {
            _ = try await base.addPathOnly("a", "/Container/Folder")
            harness.engine.makeAccessibleWithoutGrant("/Container")

            let lease = try #require(try await harness.store.lease(covering: URL(filePath: "/Container/Folder/file.txt")))

            #expect(lease.url.path(percentEncoded: false) == "/Container/Folder/")
            lease.end()
        }
    }

    @Suite("Availability")
    struct PathAvailability {
        @Test func anExistingItemIsAvailable() async throws {
            let base = StorePathOnlyTests()
            _ = try await base.addPathOnly("a", "/Users/me/A")

            #expect(try await base.harness.store.availability("a") == .available)
            #expect(base.harness.engine.calls.resolutions == 0)
        }

        @Test func aMissingItemIsUnknownInTheSandbox() async throws {
            let base = StorePathOnlyTests()
            _ = try await base.addPathOnly("a", "/Users/me/Gone", exists: false)

            #expect(try await base.harness.store.availability("a") == .unknown)
        }

        @Test func aMissingItemIsMissingOutsideTheSandbox() async throws {
            let harness = StoreHarness(environment: Fixtures.unsandboxedMac)
            _ = try await harness.store.add(pathOnly: URL(filePath: "/Users/me/Gone"), key: "a", metadata: Tag(name: "a"))

            #expect(try await harness.store.availability("a") == .missing)
        }

        @Test func anUnmountedVolumeIsReportedEverywhere() async throws {
            let harness = StoreHarness()
            _ = try await harness.store.add(pathOnly: URL(filePath: "/Volumes/Backup/Builds"), key: "a", metadata: Tag(name: "a"))

            #expect(try await harness.store.availability("a") == .volumeUnavailable(name: "Backup"))
        }

        @Test func aVolumeThatDoesntAnswerIsUnknown() async throws {
            let engine = Fixtures.engine()
            engine.addItem(at: "/Users/me/A")
            let service = BookmarkService(engine: HangingInspection(base: engine), executor: Fixtures.executor, timeout: .milliseconds(20), ledger: ScopeLedger())
            let store = TestStore(persistence: InMemoryPersistence(), service: service)
            _ = try await store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "a", metadata: Tag(name: "a"))

            #expect(try await store.availability("a") == .unknown)
        }

        @Test func unknownKeysFail() async {
            await #expect(throws: TestStore.Failure.self) { try await StoreHarness().store.availability("nope") }
        }
    }

    @Suite("Last known path")
    struct LastKnownPath {
        let base = StorePathOnlyTests()
        var harness: StoreHarness { base.harness }

        @Test func movesAPathOnlyRecord() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Old")
            harness.engine.addItem(at: "/Users/me/New")
            let changes = try await harness.store.updates()

            let record = try await harness.store.updateLastKnownPath("a", to: URL(filePath: "/Users/me/New/"))

            #expect(record.lastKnownPath == "/Users/me/New")
            #expect(record.fileIdentity == harness.engine.fileIdentity(of: URL(filePath: "/Users/me/New")))
            #expect(record.status == .unknown)
            #expect(harness.saved.first?.lastKnownPath == "/Users/me/New")
            #expect(await collect(changes, count: 1) == ["updated a"])
        }

        @Test func forgetsTheStatusOfTheOldPath() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/Old")
            _ = try? await harness.store.lease("a")
            #expect(try await harness.store.record("a")?.status.failure == .denied)

            let record = try await harness.store.updateLastKnownPath("a", to: URL(filePath: "/Users/me/New"))

            #expect(record.status == .unknown)
            #expect(record.fileIdentity == nil)
        }

        @Test func isAHintForABookmarkUntilItResolves() async throws {
            let original = try await harness.add("a", "/Users/me/A")

            let hinted = try await harness.store.updateLastKnownPath("a", to: URL(filePath: "/Users/me/Renamed"))
            try await harness.store.lease("a").end()

            #expect(hinted.lastKnownPath == "/Users/me/Renamed")
            #expect(hinted.data == original.data)
            #expect(hinted.fileIdentity == original.fileIdentity)
            #expect(hinted.status == .available)
            #expect(try await harness.store.record("a")?.lastKnownPath == "/Users/me/A")
            #expect(harness.engine.isBalanced)
        }

        @Test func anActiveLeaseSurvivesAHint() async throws {
            try await harness.add("a", "/Users/me/A")
            let lease = try await harness.store.lease("a")

            try await harness.store.updateLastKnownPath("a", to: URL(filePath: "/Users/me/Renamed"))

            #expect(harness.store.activeLease(for: "a") != nil)
            lease.end()
        }

        @Test func theSamePathSavesNothing() async throws {
            _ = try await base.addPathOnly("a", "/Users/me/A")
            let saves = harness.persistence.saveCount

            try await harness.store.updateLastKnownPath("a", to: URL(filePath: "/Users/me/A"))

            #expect(harness.persistence.saveCount == saves)
        }

        @Test func unknownKeysFail() async {
            let error = await #expect(throws: TestStore.Failure.self) {
                try await harness.store.updateLastKnownPath("nope", to: URL(filePath: "/x"))
            }

            guard case .notFound("nope") = error else {
                Issue.record("Expected notFound, got \(String(describing: error))")
                return
            }
        }
    }

    @Suite("Copying")
    struct Copying {
        @Test func aCopiedPathOnlyRecordTakesThisStoresKind() async throws {
            let source = StoreHarness(environment: Fixtures.iOS)
            let record = try await source.store.add(pathOnly: URL(filePath: "/Users/me/A"), key: "a", metadata: Tag(name: "a"))
            let destination = StoreHarness()

            let copy = try await destination.store.add(copyOf: record, key: "b", metadata: Tag(name: "b"))

            #expect(record.kind == .implicit)
            #expect(copy.kind == .appScoped(.readWrite))
            #expect(!copy.hasBookmark)
            #expect(copy.lastUsedAt == record.lastUsedAt)
        }

        @Test func pinningIsntCopied() async throws {
            let source = StoreHarness()
            let record = try await source.add("a", "/Users/me/A")
            try await source.store.setPinned(true, for: "a")
            let pinned = try #require(try await source.store.record("a"))
            let destination = StoreHarness()

            let copy = try await destination.store.add(copyOf: pinned, key: "b", metadata: Tag(name: "b"))

            #expect(pinned.isPinned)
            #expect(!copy.isPinned)
            #expect(copy.data == record.data)
        }
    }
}

/// An engine whose item inspection hangs, standing in for a volume that doesn't answer.
struct HangingInspection: FileSystemEngine {
    let base: FakeBookmarkEngine
    var environment: SandboxEnvironment { base.environment }

    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions, includingResourceValuesFor keys: Set<URLResourceKey>, relativeTo document: URL?) throws -> BookmarkData {
        try base.makeBookmark(for: url, options: options, includingResourceValuesFor: keys, relativeTo: document)
    }
    func resolve(_ data: BookmarkData, options: URL.BookmarkResolutionOptions, relativeTo document: URL?) throws -> (url: URL, isStale: Bool) {
        try base.resolve(data, options: options, relativeTo: document)
    }
    func recordedValues(in data: BookmarkData) -> RecordedValues? { base.recordedValues(in: data) }
    func startAccessing(_ url: URL) -> Bool { base.startAccessing(url) }
    func stopAccessing(_ url: URL) { base.stopAccessing(url) }
    func isVolumeMounted(atPath path: String) -> Bool { base.isVolumeMounted(atPath: path) }
    func fileIdentity(of url: URL) -> FileIdentity? { base.fileIdentity(of: url) }
    func itemInfo(at url: URL) -> ItemInfo? {
        Thread.sleep(forTimeInterval: 0.2)
        return base.itemInfo(at: url)
    }
    func namesAreCaseSensitive(at url: URL) -> Bool { base.namesAreCaseSensitive(at: url) }
    func writeAliasFile(_ data: BookmarkData, to url: URL) throws { try base.writeAliasFile(data, to: url) }
    func aliasFileData(at url: URL) throws -> BookmarkData { try base.aliasFileData(at: url) }
}
