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
        #expect(try harness.store.record("a") == original)
        #expect(harness.engine.isBalanced)
    }

    @Test func aStatusThatCannotBeSavedIsNotApplied() async throws {
        let harness = StoreHarness()
        try await harness.add("a", "/Users/me/A")
        harness.engine.removeItem(at: "/Users/me/A")
        harness.persistence.failSaves(1)

        let error = await #expect(throws: TestStore.Failure.self) { try await harness.store.lease("a") }

        #expect(error?.bookmarkFailure == .missing)
        #expect(try harness.store.record("a")?.status == .available)
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
        #expect(try store.record("a") == nil)
        #expect(harness.saved.isEmpty)
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
        #expect(try harness.store.record("old")?.status.failure == .corrupt)
    }
}

@Suite("Persistence read failures")
struct PersistenceReadFailureTests {
    @Test func unreadableFilesReportReadFailures() throws {
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
