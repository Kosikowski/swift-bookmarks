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
        let documents = Fixtures.service(engine).documents(anchoredOn: URL(filePath: "/Users/me/Report.pages"))

        _ = try await documents.create(for: engine.grant("/Users/me/chart.png", origin: .openPanel))

        #expect(engine.isBalanced)
    }

    @Test func documentBookmarksBalanceRefusedGrants() async {
        let engine = Fixtures.engine()
        engine.addItem(at: "/Users/me/Report.pages", isDirectory: false)
        engine.addItem(at: "/Users/me/Folder")
        let documents = Fixtures.service(engine).documents(anchoredOn: URL(filePath: "/Users/me/Report.pages"))

        await #expect(throws: BookmarkError.self) {
            try await documents.create(for: engine.grant("/Users/me/Folder", origin: .appKitDrop))
        }

        #expect(engine.isBalanced)
    }

    @Test func aliasFilesBalancePanelGrants() async throws {
        let engine = Fixtures.engine()
        engine.addItem(at: "/Users/me/Target")
        engine.makeAccessibleWithoutGrant("/Users/me/Desktop")

        try await Fixtures.service(engine).aliasFiles.write(
            aliasTo: engine.grant("/Users/me/Target", origin: .openPanel),
            at: URL(filePath: "/Users/me/Desktop/Target alias")
        )

        #expect(engine.isBalanced)
    }

    @Test func unusedImplicitStartsAreBalancedWhenReleased() async throws {
        let engine = Fixtures.engine(Fixtures.iOS)
        engine.addItem(at: "/Documents/Folder")
        let service = Fixtures.service(engine)
        let data = try await service.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))

        do {
            let resolved = try await service.resolve(data, policy: ResolutionPolicy(startsImplicitAccess: true))
            #expect(!resolved.wasStale)
            #expect(engine.isAccessing("/Documents/Folder"))
        }

        #expect(engine.isBalanced)
    }

    @Test func rejectedGrantsCanBeRelinquishedTogether() {
        let engine = Fixtures.engine()
        let grants = ["/a", "/b", "/c"].map { path -> Grant in
            engine.addItem(at: path)
            return engine.grant(path, origin: .appKitDrop)
        }

        Fixtures.service(engine).relinquish(grants)

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
        let store = TestStore(persistence: persistence, service: Fixtures.service(engine))
        engine.addItem(at: "/A")
        try await store.add(engine.grant("/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))
        persistence.blockNextSave()

        let writer = Task.detached { try await store.updateMetadata("a") { $0.name = "renamed" } }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                persistence.saving.wait()
                continuation.resume()
            }
        }

        #expect(try await store.record("a")?.metadata.name == "a")

        persistence.release.signal()
        try await writer.value
        #expect(try await store.record("a")?.metadata.name == "renamed")
    }
}
