@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: snapshots")
struct StoreSnapshotTests {
    let harness = StoreHarness(records: [StoreLoadingTests.record("a"), StoreLoadingTests.record("b")])

    @Test func isEmptyUntilTheRecordsLoad() async throws {
        let before = harness.store.snapshot

        try await harness.store.load()

        #expect(!before.isLoaded)
        #expect(before.isEmpty)
        #expect(harness.store.snapshot.isLoaded)
        #expect(harness.store.snapshot.keys == ["a", "b"])
    }

    @Test func followsEveryChange() async throws {
        try await harness.add("c", "/Users/me/C")
        #expect(harness.store.snapshot.keys == ["a", "b", "c"])

        try await harness.store.forget("a")
        #expect(harness.store.snapshot.keys == ["b", "c"])

        try await harness.store.updateMetadata("b") { $0.name = "renamed" }
        #expect(harness.store.snapshot["b"]?.metadata.name == "renamed")

        try await harness.store.move("c", to: 0)
        #expect(harness.store.snapshot.keys == ["c", "b"])
    }

    @Test func answersLookups() async throws {
        try await harness.store.load()
        let snapshot = harness.store.snapshot

        #expect(snapshot["a"]?.key == "a")
        #expect(snapshot["nope"] == nil)
        #expect(snapshot.contains("b"))
        #expect(!snapshot.contains("nope"))
        #expect(snapshot.count == 2)
        #expect(!snapshot.isEmpty)
        #expect(snapshot.records == (try await harness.store.records()))
    }

    @Test func changesBeforeSubscribersHearOfIt() async throws {
        let updates = try await harness.store.updates()
        let store = harness.store

        try await harness.add("c", "/Users/me/C")

        for await update in updates {
            guard case .change(.added(let record)) = update else { continue }
            #expect(store.snapshot[record.key] == record)
            break
        }
    }

    @Test func aFailedSaveLeavesItAsItWas() async throws {
        try await harness.store.load()
        let before = harness.store.snapshot
        harness.persistence.failSaves(1)

        await #expect(throws: TestStore.Failure.self) { try await harness.add("c", "/Users/me/C") }

        #expect(harness.store.snapshot == before)
    }

    @Test func showsWhatAnotherProcessSavedAfterAReload() async throws {
        try await harness.store.load()
        harness.persistence.replaceStoredRecords([StoreLoadingTests.record("z")])

        try await harness.store.reload()

        #expect(harness.store.snapshot.keys == ["z"])
    }

    @Test func aFailedLoadLeavesItUnloaded() async {
        harness.persistence.failLoads(1)

        await #expect(throws: TestStore.Failure.self) { try await harness.store.load() }

        #expect(!harness.store.snapshot.isLoaded)
    }

    @MainActor
    @Test func readsSynchronouslyOnTheMainActor() async throws {
        try await harness.store.load()

        let names = harness.store.snapshot.records.map(\.metadata.name)

        #expect(names == ["a", "b"])
    }

    @Test func keepsTheFirstRecordOfAKey() {
        let snapshot = StoreSnapshot(records: [StoreLoadingTests.record("a"), StoreLoadingTests.record("a", tag: "second")])

        #expect(snapshot["a"]?.metadata.name == "a")
        #expect(snapshot.isLoaded)
        #expect(snapshot != StoreSnapshot(records: snapshot.records, isLoaded: false))
    }
}

@Suite("BookmarkRecord: path-only records, use and pinning")
struct RecordFieldsTests {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func record(data: Data = Data([1, 2]), lastUsedAt: Date? = nil, isPinned: Bool = false, path: String = "/Users/me/A") -> TestRecord {
        TestRecord(
            key: "a",
            data: BookmarkData(data),
            kind: .appScoped(.readWrite),
            lastKnownPath: path,
            createdAt: date,
            lastUsedAt: lastUsedAt,
            isPinned: isPinned,
            metadata: Tag(name: "a")
        )
    }

    static func object(_ record: TestRecord) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
    }

    @Test func pathOnlyRecordsAreWrittenWithoutData() throws {
        let object = try Self.object(Self.record(data: Data()))

        #expect(object["data"] == nil)
        #expect(object["lastKnownPath"] as? String == "/Users/me/A")
    }

    @Test func recordsWithABookmarkKeepTheirData() throws {
        #expect(try Self.object(Self.record())["data"] as? String == Data([1, 2]).base64EncodedString())
    }

    @Test func useAndPinningAreWrittenOnlyWhenSet() throws {
        let plain = try Self.object(Self.record())
        let set = try Self.object(Self.record(lastUsedAt: Self.date, isPinned: true))

        #expect(plain["lastUsedAt"] == nil)
        #expect(plain["isPinned"] == nil)
        #expect(set["lastUsedAt"] != nil)
        #expect(set["isPinned"] as? Bool == true)
    }

    @Test(arguments: [
        RecordFieldsTests.record(data: Data()),
        RecordFieldsTests.record(lastUsedAt: RecordFieldsTests.date, isPinned: true),
        RecordFieldsTests.record(),
    ])
    func roundTrip(_ record: TestRecord) throws {
        let data = try JSONEncoder().encode(record)

        #expect(try JSONDecoder().decode(TestRecord.self, from: data) == record)
    }

    /// Versions before path-only records required `data`, so they can't read one and keep it
    /// as it is instead of resolving empty bytes.
    @Test func earlierVersionsCantReadAPathOnlyRecord() throws {
        struct EarlierRecord: Decodable {
            let data: Data
        }
        let data = try JSONEncoder().encode(Self.record(data: Data()))

        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EarlierRecord.self, from: data) }
        #expect(try JSONDecoder().decode(EarlierRecord.self, from: JSONEncoder().encode(Self.record())).data == Data([1, 2]))
    }

    @Test func theEnvelopeKeepsPathOnlyRecords() throws {
        let records = [Self.record(data: Data(), lastUsedAt: Self.date, isPinned: true)]

        let stored = try PersistedEnvelope<String, Tag>.decode(PersistedEnvelope<String, Tag>.encode(records, pretty: false))

        #expect(stored.records == records)
        #expect(stored.preserved.isEmpty)
        #expect(stored.unknownFields.isEmpty)
    }

    @Test func describesItsItem() {
        #expect(!Self.record(data: Data()).hasBookmark)
        #expect(Self.record().hasBookmark)
        #expect(Self.record(path: "/Users/me/.Trash/A").isInTrash)
        #expect(Self.record(path: "/Users/me/.Trash/A").isGone)
        var missing = Self.record()
        missing.status = .unavailable(.missing, since: Self.date)
        #expect(missing.isGone)
        missing.status = .unavailable(.volumeUnavailable(name: "X"), since: Self.date)
        #expect(!missing.isGone)
        #expect(BookmarkData(Data()).isEmpty)
    }
}

@Suite("BookmarkStore: path-only records in files")
struct PathOnlyPersistenceTests {
    @Test func aJSONFileKeepsPathOnlyRecordsAcrossStores() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "path-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "bookmarks.json")
        let engine = Fixtures.engine()
        let service = Fixtures.service(engine)
        let first = TestStore(persistence: JSONFilePersistence(fileURL: file), service: service)
        _ = try await first.add(pathOnly: URL(filePath: "/Users/me/A"), key: "a", metadata: Tag(name: "a"))
        try await first.setPinned(true, for: "a")

        let second = TestStore(persistence: JSONFilePersistence(fileURL: file), service: service)
        let record = try #require(try await second.record("a"))

        #expect(!record.hasBookmark)
        #expect(record.isPinned)
        #expect(record.lastKnownPath == "/Users/me/A")
    }

    @Test func aLegacyFormatKeepsUseAndPinningInMemory() async throws {
        let engine = Fixtures.engine()
        let store = TestStore(persistence: LegacyFormat(), service: Fixtures.service(engine))
        engine.addItem(at: "/Users/me/A")
        engine.addItem(at: "/Users/me/B")
        try await store.add(engine.grant("/Users/me/A", origin: .openPanel), key: "a", metadata: Tag(name: "a"))
        try await store.setPinned(true, for: "a")

        try await store.add(engine.grant("/Users/me/B", origin: .openPanel), key: "b", metadata: Tag(name: "b"))

        let record = try #require(try await store.record("a"))
        #expect(record.isPinned)
        #expect(record.lastUsedAt != nil)
    }
}
