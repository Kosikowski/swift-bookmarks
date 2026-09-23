@testable import Bookmarks
import BookmarksTesting
import Foundation
import Synchronization
import Testing

@Suite("Regressions")
struct RegressionTests {
    @Test func documentBookmarksBalancePanelGrants() async throws {
        let engine = Fixtures.engine()
        engine.addItem(at: "/Users/me/Report.pages", isDirectory: false)
        engine.addItem(at: "/Users/me/chart.png", isDirectory: false)
        let documents = DocumentBookmarks(document: URL(filePath: "/Users/me/Report.pages"), bookmarks: Fixtures.bookmarks(engine))

        _ = try await documents.create(for: engine.grant("/Users/me/chart.png", origin: .openPanel))

        #expect(engine.isBalanced)
    }

    @Test func documentBookmarksBalanceRefusedGrants() async {
        let engine = Fixtures.engine()
        engine.addItem(at: "/Users/me/Report.pages", isDirectory: false)
        engine.addItem(at: "/Users/me/Folder")
        let documents = DocumentBookmarks(document: URL(filePath: "/Users/me/Report.pages"), bookmarks: Fixtures.bookmarks(engine))

        await #expect(throws: BookmarkError.self) {
            try await documents.create(for: engine.grant("/Users/me/Folder", origin: .drop))
        }

        #expect(engine.isBalanced)
    }

    @Test func aliasFilesBalancePanelGrants() async throws {
        let engine = Fixtures.engine()
        engine.addItem(at: "/Users/me/Target")
        engine.makeAccessibleWithoutGrant("/Users/me/Desktop")

        try await AliasFiles(bookmarks: Fixtures.bookmarks(engine)).write(
            aliasTo: engine.grant("/Users/me/Target", origin: .openPanel),
            at: URL(filePath: "/Users/me/Desktop/Target alias")
        )

        #expect(engine.isBalanced)
    }

    @Test func unusedImplicitStartsAreBalancedWhenReleased() async throws {
        let engine = Fixtures.engine(Fixtures.iOS)
        engine.addItem(at: "/Documents/Folder")
        let bookmarks = Fixtures.bookmarks(engine)
        let data = try await bookmarks.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))

        do {
            let resolved = try await bookmarks.resolve(data, policy: ResolutionPolicy(startsImplicitAccess: true))
            #expect(!resolved.wasStale)
            #expect(engine.isAccessing("/Documents/Folder"))
        }

        #expect(engine.isBalanced)
    }

    @Test func rejectedGrantsCanBeRelinquishedTogether() {
        let engine = Fixtures.engine()
        let grants = ["/a", "/b", "/c"].map { path -> Grant in
            engine.addItem(at: path)
            return engine.grant(path, origin: .drop)
        }

        Fixtures.bookmarks(engine).relinquish(grants)

        #expect(engine.isBalanced)
    }

    @Test func contentionHasItsOwnError() {
        let error = BookmarkStoreError<String>.changedDuringAccess("a")

        #expect(error.errorDescription?.contains("Try again") == true)
        #expect(error.bookmarkFailure == nil)
    }
}

@Suite("Store writes and reads")
struct StoreWriteIsolationTests {
    final class SlowPersistence: BookmarkPersistence {
        let base = InMemoryPersistence<String, Tag>()
        let saving = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let blocking = Atomic(false)

        func blockNextSave() { blocking.store(true, ordering: .relaxed) }

        func load() throws(PersistenceError) -> [BookmarkRecord<String, Tag>] { try base.load() }

        func save(_ records: [BookmarkRecord<String, Tag>]) throws(PersistenceError) {
            if blocking.exchange(false, ordering: .relaxed) {
                saving.signal()
                release.wait()
            }
            try base.save(records)
        }
    }

    @Test func readsDoNotWaitForASaveInProgress() async throws {
        let engine = Fixtures.engine()
        let persistence = SlowPersistence()
        let store = TestStore(persistence: persistence, bookmarks: Fixtures.bookmarks(engine))
        engine.addItem(at: "/A")
        try await store.add(engine.grant("/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))
        persistence.blockNextSave()

        let writer = Task.detached { try store.updateMetadata("a") { $0.name = "renamed" } }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                persistence.saving.wait()
                continuation.resume()
            }
        }

        #expect(try store.record("a")?.metadata.name == "a")

        persistence.release.signal()
        try await writer.value
        #expect(try store.record("a")?.metadata.name == "renamed")
    }
}

@Suite("Migration markers")
struct MigrationMarkerTests {
    final class Flag: Sendable {
        private let value = Atomic(false)
        var isSet: Bool { value.load(ordering: .relaxed) }
        func set() { value.store(true, ordering: .relaxed) }
    }

    static let legacyRecord = TestRecord(key: "legacy", data: BookmarkData(Data([1])), kind: .reference, lastKnownPath: "/legacy", createdAt: Date(), metadata: Tag(name: "legacy"))

    @Test func completedMigrationsDoNotResurrectDeletedRecords() throws {
        let base = InMemoryPersistence<String, Tag>()
        let flag = Flag()
        let migrating = MigratingPersistence(
            base: base,
            legacy: { [Self.legacyRecord] },
            marker: MigrationMarker(isComplete: { flag.isSet }, markComplete: { flag.set() })
        )

        #expect(try migrating.load() == [Self.legacyRecord])
        try migrating.save([])

        #expect(try migrating.load().isEmpty)
        #expect(flag.isSet)
    }

    @Test func cleanUpOnlyReimportsWhenLegacyDataRemains() throws {
        let migrating = MigratingPersistence(base: InMemoryPersistence<String, Tag>(), legacy: { [Self.legacyRecord] })

        _ = try migrating.load()
        try migrating.save([])

        #expect(try migrating.load() == [Self.legacyRecord])
    }

    @Test func existingRecordsMarkTheMigrationComplete() throws {
        let flag = Flag()
        let migrating = MigratingPersistence(
            base: InMemoryPersistence(records: [Self.legacyRecord]),
            legacy: { nil },
            marker: MigrationMarker(isComplete: { flag.isSet }, markComplete: { flag.set() })
        )

        _ = try migrating.load()

        #expect(flag.isSet)
    }

    @Test func failedLegacyReadsLeaveTheMarkerUnset() {
        let flag = Flag()
        let migrating = MigratingPersistence(
            base: InMemoryPersistence<String, Tag>(),
            legacy: { () throws(PersistenceError) -> [TestRecord]? in throw PersistenceError(.readFailed) },
            marker: MigrationMarker(isComplete: { flag.isSet }, markComplete: { flag.set() })
        )

        #expect(throws: PersistenceError.self) { try migrating.load() }
        #expect(!flag.isSet)
    }

    @Test func userDefaultsMarkerPersistsCompletion() {
        let suite = "swift-bookmarks.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let marker = MigrationMarker.userDefaults(key: "migrated", suiteName: suite)

        #expect(!marker.isComplete)
        marker.markComplete()

        #expect(MigrationMarker.userDefaults(key: "migrated", suiteName: suite).isComplete)
        #expect(!MigrationMarker.cleanUpOnly.isComplete)
    }

    @Test func standardDefaultsMarker() {
        let key = "swift-bookmarks.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        MigrationMarker.userDefaults(key: key).markComplete()

        #expect(UserDefaults.standard.bool(forKey: key))
    }
}
