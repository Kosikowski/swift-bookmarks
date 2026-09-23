@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

/// Keeps keys, bytes, kind, path and metadata, as a legacy format does, and loses the rest.
struct LegacyFormat: BookmarkPersistence {
    let stored = ScriptedPersistence<String, Tag>()

    var storesRecordState: Bool { false }

    func load() throws(PersistenceError) -> [TestRecord] {
        try stored.load().map(Self.stripped)
    }

    func save(_ records: [TestRecord]) throws(PersistenceError) {
        try stored.save(records.map(Self.stripped))
    }

    static func stripped(_ record: TestRecord) -> TestRecord {
        TestRecord(
            key: record.key,
            data: record.data,
            kind: record.kind,
            lastKnownPath: record.lastKnownPath,
            createdAt: .distantPast,
            metadata: record.metadata
        )
    }
}

@Suite("BookmarkStore: persistences that can't store state")
struct StoreRecordStateTests {
    let engine = Fixtures.engine()
    let persistence = LegacyFormat()
    let store: TestStore

    init() {
        store = TestStore(persistence: persistence, service: Fixtures.service(engine))
    }

    func add(_ key: String, _ path: String) async throws {
        engine.addItem(at: path)
        try await store.add(engine.grant(path, origin: .openPanel), key: key, metadata: Tag(name: key))
    }

    @Test func aStatusSurvivesAWriteToAnotherRecord() async throws {
        try await add("a", "/Users/me/A")
        try await add("b", "/Users/me/B")
        engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
        await #expect(throws: TestStore.Failure.self) { try await store.lease("a") }

        try await store.updateMetadata("b") { $0.name = "renamed" }

        #expect(try await store.record("a")?.status.failure == .needsRegrant)
        #expect(try await store.record("a")?.createdAt != .distantPast)
    }

    @Test func aStatusSurvivesAReload() async throws {
        try await add("a", "/Users/me/A")
        engine.failResolution(of: "/Users/me/A", with: FakeErrors.corrupt)
        await #expect(throws: TestStore.Failure.self) { try await store.lease("a") }

        try await store.reload()

        #expect(try await store.record("a")?.status.failure == .needsRegrant)
    }

    @Test func thePathTheStoreKnowsWinsOverTheOneLoadedForTheSameBytes() async throws {
        try await add("a", "/Users/me/A")
        try await add("b", "/Users/me/B")
        // An adapter that reads the path out of the bookmark finds the one it was made at.
        persistence.stored.replaceStoredRecords(persistence.stored.storedRecords.map { record in
            var record = record
            if record.key == "a" { record.lastKnownPath = "/Users/me/Recorded" }
            return record
        })
        let updates = try await store.updates()
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()

        try await store.updateMetadata("b") { $0.name = "renamed" }

        #expect(try await store.record("a")?.lastKnownPath == "/Users/me/A")
        guard case .change(let change) = await iterator.next() else {
            Issue.record("Expected a change")
            return
        }
        #expect(change.summary == "updated b")
    }

    @Test func newBytesTakeWhatWasLoaded() async throws {
        try await add("a", "/Users/me/A")
        try await store.withAccess(to: "a") { _ in }
        persistence.stored.replaceStoredRecords(persistence.stored.storedRecords.map { record in
            var record = record
            record.data = BookmarkData(Data("other".utf8))
            return record
        })

        try await store.reload()

        #expect(try await store.record("a")?.status == .unknown)
    }

    @Test func aChangeThatAltersNothingSavesNothing() async throws {
        try await add("a", "/Users/me/A")
        try await store.withAccess(to: "a") { _ in }
        let saves = persistence.stored.saveCount

        try await store.withAccess(to: "a") { _ in }
        try await store.forget("missing")

        #expect(persistence.stored.saveCount == saves)
    }
}
