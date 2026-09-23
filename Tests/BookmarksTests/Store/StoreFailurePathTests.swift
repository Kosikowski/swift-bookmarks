@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: failure paths")
struct StoreFailurePathTests {
    @Test func aFailedRegrantLeavesTheRecordUnchanged() async throws {
        let harness = StoreHarness()
        let original = try await harness.add("a", "/Users/me/A")
        harness.engine.addItem(at: "/Users/me/B")
        harness.engine.failCreation(of: "/Users/me/B", with: FakeErrors.denied)

        let error = await #expect(throws: TestStore.Failure.self) {
            try await harness.store.regrant("a", with: harness.engine.grant("/Users/me/B", origin: .openPanel))
        }

        #expect(error?.bookmarkFailure == .denied)
        #expect(try await harness.store.record("a") == original)
        #expect(harness.engine.isBalanced)
    }

    @Test func aStatusThatCannotBeSavedIsNotApplied() async throws {
        let harness = StoreHarness()
        try await harness.add("a", "/Users/me/A")
        harness.engine.removeItem(at: "/Users/me/A")
        harness.persistence.failSaves(1)

        let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

        #expect(error?.bookmarkFailure == .missing)
        #expect(try await harness.store.record("a")?.status == .available)
    }

    @Test func aRecordThatKeepsFailingIsNotWrittenAgain() async throws {
        let harness = StoreHarness()
        try await harness.add("a", "/Users/me/A")
        harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
        await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }
        let updates = harness.persistence.updateCount

        await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

        #expect(harness.persistence.updateCount == updates)
        #expect(harness.saved.first?.status.failure == .needsRegrant)
    }

    @Test func forgettingDuringAFailingResolutionIsNotUndone() async throws {
        let harness = StoreHarness(policy: StorePolicy(failureHandling: .keep))
        try await harness.add("a", "/Users/me/A")
        harness.engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
        let gate = harness.engine.holdResolution(of: "/Users/me/A")
        let store = harness.store

        let task = Task { try await store.lease("a") }
        await gate.waitUntilReached()
        try await store.forget("a")
        gate.open()

        await #expect(throws: TestStore.Failure.self) { try await task.value }
        #expect(try await store.record("a") == nil)
        #expect(harness.saved.isEmpty)
    }

    @Test func savesDontWaitForHungSystemCalls() async throws {
        let engine = Fixtures.engine()
        let service = BookmarkService(engine: engine, executor: BlockingExecutor(label: "tests.single", width: 1))
        let store = TestStore(persistence: InMemoryPersistence(), service: service)
        engine.addItem(at: "/Users/me/A")
        try await store.add(engine.grant("/Users/me/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))
        let gate = engine.holdResolution(of: "/Users/me/A")

        let hung = Task { try await store.lease("a") }
        await gate.waitUntilReached()
        try await store.updateMetadata("a") { $0.name = "renamed" }
        gate.open()

        #expect(try await store.record("a")?.metadata.name == "renamed")
        try await hung.value.end()
    }

    @Test func refreshingStatusesSkipsAvailableRecords() async throws {
        let harness = StoreHarness()
        try await harness.add("a", "/Users/me/A")
        let resolutions = harness.engine.calls.resolutions

        #expect(try await harness.store.refreshStatuses().isEmpty)
        #expect(harness.engine.calls.resolutions == resolutions)
    }

    @Test func refreshingStatusesMarksRecordsThatStillFail() async throws {
        let records = [TestRecord(key: "old", data: BookmarkData(Data("x".utf8)), kind: .appScoped(.readWrite), lastKnownPath: "/Old", createdAt: Date(), metadata: Tag(name: "old"))]
        let harness = StoreHarness(records: records)

        #expect(try await harness.store.refreshStatuses().isEmpty)
        #expect(try await harness.store.record("old")?.status.failure == .corrupt)
    }

    /// A change that fails to save.
    enum Change: String, CaseIterable, Sendable {
        case forget, removeAll, move, updateMetadata

        func apply(to store: TestStore) async throws {
            switch self {
            case .forget: try await store.forget("a")
            case .removeAll: try await store.removeAll()
            case .move: try await store.move("a", to: 1)
            case .updateMetadata: try await store.updateMetadata("a") { $0.name = "renamed" }
            }
        }
    }

    @Test(arguments: Change.allCases)
    func aChangeThatFailsToSaveKeepsRecordsLeasesAndSubscribersAsTheyWere(_ change: Change) async throws {
        let harness = StoreHarness()
        try await harness.add("a", "/Users/me/A")
        try await harness.add("b", "/Users/me/B")
        let records = try await harness.store.records()
        let lease = try await harness.store.lease("a")
        let updates = try await harness.store.updates()
        harness.persistence.failSaves(1)

        let error = await #expect(throws: TestStore.Failure.self) { try await change.apply(to: harness.store) }
        try await harness.store.updateMetadata("b") { $0.name = "after" }

        guard case .persistence(let persistenceError) = error else {
            Issue.record("Expected a persistence error, got \(String(describing: error))")
            return
        }
        #expect(persistenceError.reason == .writeFailed)
        #expect(try await harness.store.records().first == records.first)
        #expect(harness.saved.map(\.key) == ["a", "b"])
        #expect(harness.store.activeKeys == ["a"])
        #expect(harness.store.activeLease(for: "a") != nil)
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await iterator.next().map { if case .change(let change) = $0 { change.summary } else { "snapshot" } } == "updated b")
        lease.end()
        #expect(harness.engine.isBalanced)
    }

    /// A backend that returns without calling the transform.
    struct SkippingPersistence: BookmarkPersistence {
        func load() throws(PersistenceError) -> [TestRecord] { [] }
        func save(_ records: [TestRecord]) throws(PersistenceError) {}
        func update(_ transform: ([TestRecord]) -> [TestRecord]?) throws(PersistenceError) {}
    }

    @Test func aBackendThatSkipsTheTransformFailsTheChange() async throws {
        let engine = Fixtures.engine()
        let store = TestStore(persistence: SkippingPersistence(), service: Fixtures.service(engine))
        let updates = try await store.updates()
        engine.addItem(at: "/Users/me/A")

        let error = await #expect(throws: TestStore.Failure.self) {
            try await store.add(engine.grant("/Users/me/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))
        }

        guard case .persistence(let persistenceError) = error else {
            Issue.record("Expected a persistence error, got \(String(describing: error))")
            return
        }
        #expect(persistenceError.reason == .writeFailed)
        #expect(try await store.keys().isEmpty)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .snapshot([]))
        #expect(engine.isBalanced)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingRefreshStatusesStopsBeforeTheNextRecord() async throws {
        let harness = StoreHarness()
        harness.engine.mountVolume(at: "/Volumes/Backup")
        for key in ["a", "b", "c"] {
            try await harness.add(key, "/Volumes/Backup/\(key)")
        }
        harness.engine.unmountVolume(at: "/Volumes/Backup")
        for key in ["a", "b", "c"] {
            _ = try? await harness.store.lease(key)
        }
        harness.engine.mountVolume(at: "/Volumes/Backup")
        let resolutions = harness.engine.calls.resolutions
        let gate = harness.engine.holdResolution(of: "/Volumes/Backup/a")
        let store = harness.store

        let task = Task { try await store.refreshStatuses() }
        await gate.waitUntilReached()
        task.cancel()
        gate.open()

        let error = await #expect(throws: TestStore.Failure.self) { try await task.value }
        #expect(error?.bookmarkFailure == .cancelled)
        // The shared resolution finishes, but no later record starts resolving.
        while await store.pendingResolutionCallers(for: "a") > 0 {
            await Task.yield()
        }
        #expect(harness.engine.calls.resolutions == resolutions + 1)
        #expect(try await store.record("c")?.status.failure == .volumeUnavailable(name: "Backup"))
    }

    @Test func refreshingStatusesReportsResolvedKeysWhoseStatusFailedToSave() async throws {
        let harness = StoreHarness()
        harness.engine.mountVolume(at: "/Volumes/Backup")
        try await harness.add("a", "/Volumes/Backup/A")
        harness.engine.unmountVolume(at: "/Volumes/Backup")
        _ = try? await harness.store.lease("a")
        harness.engine.mountVolume(at: "/Volumes/Backup")
        harness.persistence.failSaves(1)

        let recovered = try await harness.store.refreshStatuses()

        #expect(recovered == ["a"])
        #expect(try await harness.store.record("a")?.status.failure == .volumeUnavailable(name: "Backup"))
        #expect(harness.saved.first?.status.failure == .volumeUnavailable(name: "Backup"))
        #expect(harness.engine.isBalanced)
    }
}

@Suite("Persistence read failures")
struct PersistenceReadFailureTests {
    @Test(.disabled(if: getuid() == 0, "File permissions don't restrict root"))
    func unreadableFilesReportReadFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swift-bookmarks-unreadable-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appending(path: "bookmarks.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))

        let error = #expect(throws: PersistenceError.self) {
            try JSONFilePersistence<String, Tag>(fileURL: file).load()
        }

        #expect(error?.reason == .readFailed)
    }

    @Test func invalidDefaultsSuitesReportReadFailures() {
        let persistence = UserDefaultsPersistence<String, Tag>(key: "bookmarks", suiteName: UserDefaults.globalDomain)

        let error = #expect(throws: PersistenceError.self) { try persistence.load() }

        #expect(error?.reason == .readFailed)
    }

    @Test func standardDefaultsAreUsedWithoutASuite() throws {
        let key = "swift-bookmarks.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let persistence = UserDefaultsPersistence<String, Tag>(key: key)

        try persistence.save([])

        #expect(UserDefaults.standard.data(forKey: key) != nil)
        #expect(try persistence.load().isEmpty)
    }
}

@Suite("Default kind")
struct DefaultKindTests {
    @Test func staticDefaultUsesTheCurrentProcess() {
        #expect(BookmarkKind.persistentDefault == BookmarkKind.persistentDefault(for: .current))
    }
}
