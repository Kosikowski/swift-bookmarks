@testable import Bookmarks
import BookmarksTesting
import Foundation
import Synchronization
import Testing

private func sampleRecords() -> [TestRecord] {
    [
        TestRecord(
            key: "a",
            data: BookmarkData(Data([1, 2, 3])),
            kind: .appScoped(.readWrite),
            lastKnownPath: "/Users/me/A",
            fileIdentity: FileIdentity(volumeUUID: "V", fileID: 9),
            status: .available,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_100),
            metadata: Tag(name: "A")
        ),
        TestRecord(
            key: "b",
            data: BookmarkData(Data([4])),
            kind: .reference,
            lastKnownPath: "/Volumes/Backup/B",
            status: .unavailable(.volumeUnavailable(name: "Backup"), since: Date(timeIntervalSince1970: 1_700_000_200)),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: Tag(name: "B")
        ),
    ]
}

@Suite("BookmarkRecord")
struct BookmarkRecordTests {
    @Test func roundTripsThroughJSON() throws {
        let records = sampleRecords()

        let decoded = try JSONDecoder().decode([TestRecord].self, from: JSONEncoder().encode(records))

        #expect(decoded == records)
    }

    @Test func statusExposesItsFailure() {
        #expect(RecordStatus.unknown.failure == nil)
        #expect(RecordStatus.available.failure == nil)
        #expect(RecordStatus.unavailable(.denied, since: Date()).failure == .denied)
    }

    @Test func displayNameIsTheLastPathComponent() {
        #expect(sampleRecords()[1].displayName == "B")
    }
}

@Suite("PersistedEnvelope")
struct PersistedEnvelopeTests {
    typealias Envelope = PersistedEnvelope<String, Tag>

    @Test func writesTheSchemaVersion() throws {
        let data = try Envelope.encode(sampleRecords(), pretty: false)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect((object["records"] as? [Any])?.count == 2)
    }

    @Test func roundTrips() throws {
        let data = try Envelope.encode(sampleRecords(), pretty: true)

        #expect(try Envelope.decode(data).records == sampleRecords())
    }

    @Test func reportsMetadataThatCantBeEncoded() {
        let record = BookmarkRecord(key: "a", data: BookmarkData(Data()), kind: .reference, lastKnownPath: "/a", createdAt: Date(), metadata: Unencodable())

        let error = #expect(throws: PersistenceError.self) { try PersistedEnvelope<String, Unencodable>.encode([record], pretty: false) }

        #expect(error?.reason == .writeFailed)
    }

    @Test func refusesNewerSchemas() {
        let data = Data(#"{"schemaVersion": 2, "records": []}"#.utf8)

        let error = #expect(throws: PersistenceError.self) { try Envelope.decode(data) }

        #expect(error?.reason == .unsupportedSchemaVersion(2))
    }

    @Test(arguments: ["not json", "{}", #"{"schemaVersion": 1}"#, #"{"schemaVersion": 1, "records": 3}"#])
    func reportsUnreadableData(_ text: String) {
        let error = #expect(throws: PersistenceError.self) { try Envelope.decode(Data(text.utf8)) }

        #expect(error?.reason == .unreadable)
    }

    @Test func keepsRecordsItCantReadVerbatim() throws {
        let data = try Envelope.encode(sampleRecords(), pretty: false)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var records = try #require(object["records"] as? [[String: Any]])
        records[1]["kind"] = "futureKind"
        records.append(["key": "c", "fileID": 18_446_744_073_709_551_615 as UInt64])
        object["records"] = records

        let stored = try Envelope.decode(JSONSerialization.data(withJSONObject: object))
        let rewritten = try Envelope.decode(Envelope.encode(stored.records, preserving: stored.preserved, pretty: false))

        #expect(stored.records == [sampleRecords()[0]])
        #expect(stored.preserved.count == 2)
        #expect(rewritten.preserved == stored.preserved)
        #expect(stored.preserved.last == .object(["key": .string("c"), "fileID": .unsigned(UInt64.max)]))
    }

    @Test func aStatusFromANewerVersionDecodesAsUnknown() throws {
        let data = try Envelope.encode(sampleRecords(), pretty: false)
        let text = try #require(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: #""code":"volumeUnavailable""#, with: #""code":"futureFailure""#)

        let stored = try Envelope.decode(Data(text.utf8))

        #expect(stored.records.map(\.status) == [.available, .unknown])
    }

    @Test func writesKindsAndFailuresAsStableCodes() throws {
        let data = try Envelope.encode(sampleRecords(), pretty: false)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains(#""kind":"appScoped.readWrite""#))
        #expect(text.contains(#""kind":"reference""#))
        #expect(text.contains(#""failure":{"code":"volumeUnavailable","volumeName":"Backup"}"#))
        #expect(text.contains(#""state":"unavailable""#))
    }
}

@Suite("InMemoryPersistence")
struct InMemoryPersistenceTests {
    @Test func startsWithTheGivenRecords() throws {
        let persistence = InMemoryPersistence(records: sampleRecords())

        #expect(try persistence.load() == sampleRecords())
        #expect(persistence.saveCount == 0)
    }

    @Test func savesReplaceEverything() throws {
        let persistence = InMemoryPersistence<String, Tag>()

        try persistence.save(sampleRecords())
        try persistence.save([sampleRecords()[1]])

        #expect(persistence.storedRecords == [sampleRecords()[1]])
        #expect(persistence.saveCount == 2)
    }
}

@Suite("UserDefaultsPersistence")
struct UserDefaultsPersistenceTests {
    let suiteName = "swift-bookmarks.tests.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    func persistence(_ corruption: CorruptionHandling = .quarantine) -> UserDefaultsPersistence<String, Tag> {
        UserDefaultsPersistence(key: "bookmarks", suiteName: suiteName, corruption: corruption)
    }

    @Test func aSaveKeepsRecordsWrittenByANewerVersion() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = persistence()
        try persistence.save(sampleRecords())
        let data = try #require(defaults.data(forKey: "bookmarks"))
        let text = try #require(String(data: data, encoding: .utf8))
        defaults.set(Data(text.replacingOccurrences(of: #""kind":"reference""#, with: #""kind":"futureKind""#).utf8), forKey: "bookmarks")

        try persistence.save([])

        #expect(try persistence.load().isEmpty)
        #expect(String(data: try #require(defaults.data(forKey: "bookmarks")), encoding: .utf8)?.contains("futureKind") == true)
    }

    @Test func emptyWhenNothingIsStored() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(try persistence().load().isEmpty)
    }

    @Test func roundTrips() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try persistence().save(sampleRecords())

        #expect(try persistence().load() == sampleRecords())
        #expect(defaults.data(forKey: "bookmarks") != nil)
    }

    @Test func quarantinesUnreadableData() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("garbage".utf8), forKey: "bookmarks")

        #expect(try persistence().load().isEmpty)

        #expect(defaults.data(forKey: "bookmarks") == nil)
        #expect(defaults.data(forKey: "bookmarks.corrupted") == Data("garbage".utf8))
        #expect(persistence().quarantineKey == "bookmarks.corrupted")
    }

    @Test func quarantinesValuesOfTheWrongType() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("a string", forKey: "bookmarks")

        #expect(try persistence().load().isEmpty)

        #expect(defaults.object(forKey: "bookmarks") == nil)
        #expect(defaults.string(forKey: "bookmarks.corrupted") == "a string")
    }

    @Test func canFailInsteadOfQuarantining() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("garbage".utf8), forKey: "bookmarks")

        let error = #expect(throws: PersistenceError.self) { try persistence(.fail).load() }

        #expect(error?.reason == .unreadable)
        #expect(defaults.data(forKey: "bookmarks") != nil)
    }

    @Test func neverQuarantinesDataFromANewerVersion() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let newer = Data(#"{"schemaVersion": 7, "records": []}"#.utf8)
        defaults.set(newer, forKey: "bookmarks")

        let error = #expect(throws: PersistenceError.self) { try persistence().load() }

        #expect(error?.reason == .unsupportedSchemaVersion(7))
        #expect(defaults.data(forKey: "bookmarks") == newer)
    }
}

@Suite("JSONFilePersistence")
struct JSONFilePersistenceTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swift-bookmarks-tests-\(UUID().uuidString)")
    var fileURL: URL { directory.appending(path: "Nested/bookmarks.json") }

    func persistence(_ corruption: CorruptionHandling = .quarantine, keepsLastGoodCopy: Bool = true) -> JSONFilePersistence<String, Tag> {
        JSONFilePersistence(fileURL: fileURL, corruption: corruption, keepsLastGoodCopy: keepsLastGoodCopy)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path(percentEncoded: false)))?.sorted() ?? []
    }

    @Test func aSaveKeepsRecordsWrittenByANewerVersion() throws {
        defer { cleanUp() }
        let persistence = persistence()
        try persistence.save(sampleRecords())
        let text = try String(contentsOf: fileURL, encoding: .utf8)
            .replacingOccurrences(of: #""kind" : "reference""#, with: #""kind" : "futureKind""#)
        try Data(text.utf8).write(to: fileURL)

        try persistence.save([])

        #expect(try persistence.load().isEmpty)
        #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("futureKind"))
    }

    @Test func updatesApplyToWhatAnotherWriterSaved() throws {
        defer { cleanUp() }
        let records = sampleRecords()
        let first = persistence()
        let second = persistence()
        try first.save([records[0]])

        try second.update { $0 + [records[1]] }

        #expect(try first.load() == records)
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsWritesByOtherWriters() async throws {
        defer { cleanUp() }
        let changes = persistence().changes()

        try persistence().save(sampleRecords())

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStoreFollowsChangesAnotherProcessSaves() async throws {
        defer { cleanUp() }
        let records = sampleRecords()
        let other = persistence()
        try other.save([records[0]])
        let store = BookmarkStore(persistence: persistence(), service: Fixtures.service(Fixtures.engine()))
        let updates = try await store.updates()
        let following = Task { await store.reload(on: persistence().changes()) }
        defer { following.cancel() }

        try other.update { $0 + [records[1]] }

        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        guard case .change(.added(let added)) = await iterator.next() else {
            Issue.record("Expected the other process's record to arrive")
            return
        }
        #expect(added == records[1])
    }

    @Test func anUpdateThatReturnsNothingDoesntWrite() throws {
        defer { cleanUp() }
        let persistence = persistence()

        try persistence.update { _ in nil }

        #expect(files().isEmpty)
    }

    @Test func emptyWhenTheFileIsMissing() throws {
        defer { cleanUp() }

        #expect(try persistence().load().isEmpty)
    }

    @Test func roundTripsAndCreatesDirectories() throws {
        defer { cleanUp() }

        try persistence().save(sampleRecords())

        #expect(try persistence().load() == sampleRecords())
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    @Test func writesReadableJSON() throws {
        defer { cleanUp() }

        try persistence().save(sampleRecords())

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.contains("\n"))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("2023-11-14T22:13:20Z"))
        #expect(text.contains("\"AQID\""))
    }

    @Test func keepsTheLastGoodCopy() throws {
        defer { cleanUp() }
        let persistence = persistence()

        try persistence.save(sampleRecords())
        try persistence.save([])

        let lastGood = try PersistedEnvelope<String, Tag>.decode(Data(contentsOf: persistence.lastGoodURL)).records
        #expect(lastGood == sampleRecords())
        #expect(persistence.lastGoodURL.lastPathComponent == "bookmarks.json.last-good")
    }

    @Test func canSkipTheLastGoodCopy() throws {
        defer { cleanUp() }

        try persistence(keepsLastGoodCopy: false).save(sampleRecords())
        try persistence(keepsLastGoodCopy: false).save([])

        #expect(files() == ["bookmarks.json"])
    }

    @Test func quarantinesACorruptFileAndRecoversTheLastGoodCopy() throws {
        defer { cleanUp() }
        let persistence = persistence()
        try persistence.save(sampleRecords())
        try persistence.save(sampleRecords())
        try Data("garbage".utf8).write(to: fileURL)

        let recovered = try persistence.load()

        #expect(recovered == sampleRecords())
        #expect(files().contains { $0.hasPrefix("bookmarks.json.corrupt-") })
        #expect(!files().contains("bookmarks.json"))
    }

    @Test func startsEmptyWhenThereIsNoGoodCopy() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: fileURL)

        #expect(try persistence().load().isEmpty)
    }

    @Test func canFailOnACorruptFile() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: fileURL)

        let error = #expect(throws: PersistenceError.self) { try persistence(.fail).load() }

        #expect(error?.reason == .unreadable)
        #expect(files() == ["bookmarks.json"])
    }

    @Test func refusesFilesFromANewerVersion() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 3, "records": []}"#.utf8).write(to: fileURL)

        let error = #expect(throws: PersistenceError.self) { try persistence().load() }

        #expect(error?.reason == .unsupportedSchemaVersion(3))
    }

    @Test func reportsWriteFailures() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appending(path: "Nested"))

        let error = #expect(throws: PersistenceError.self) { try persistence().save(sampleRecords()) }

        #expect(error?.reason == .writeFailed)
    }

    @Test func worksAsAStoreBackend() async throws {
        defer { cleanUp() }
        let records = sampleRecords()
        try persistence().save(records)

        let store = TestStore(persistence: persistence())
        try await store.updateMetadata("a") { $0.name = "Renamed" }

        #expect(try persistence().load().first?.metadata.name == "Renamed")
    }
}

@Suite("MigratingPersistence")
struct MigratingPersistenceTests {
    final class Flag: Sendable {
        private let value = Atomic(false)
        var isSet: Bool { value.load(ordering: .relaxed) }
        func set() { value.store(true, ordering: .relaxed) }
        var marker: MigrationMarker { MigrationMarker(isComplete: { self.isSet }, markComplete: { self.set() }) }
    }

    final class CleanUpCounter: Sendable {
        private let count = Mutex(0)
        func increment() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    @Test func importsLegacyRecordsOnceAndThenCleansUp() throws {
        let base = InMemoryPersistence<String, Tag>()
        let counter = CleanUpCounter()
        let flag = Flag()
        let migrating = MigratingPersistence(base: base, marker: flag.marker, legacy: { sampleRecords() }, cleanUp: { counter.increment() })

        #expect(try migrating.load() == sampleRecords())
        #expect(base.storedRecords == sampleRecords())
        #expect(counter.value == 1)
        #expect(flag.isSet)

        #expect(try migrating.load() == sampleRecords())
        #expect(counter.value == 1)
    }

    @Test func completedMigrationsDoNotResurrectDeletedRecords() throws {
        let flag = Flag()
        let migrating = MigratingPersistence(base: InMemoryPersistence<String, Tag>(), marker: flag.marker, legacy: { sampleRecords() })

        #expect(try migrating.load() == sampleRecords())
        try migrating.save([])

        #expect(try migrating.load().isEmpty)
    }

    @Test func existingRecordsMarkTheMigrationComplete() throws {
        let flag = Flag()
        let counter = CleanUpCounter()
        let migrating = MigratingPersistence(
            base: InMemoryPersistence(records: [sampleRecords()[1]]),
            marker: flag.marker,
            legacy: { sampleRecords() },
            cleanUp: { counter.increment() }
        )

        #expect(try migrating.load() == [sampleRecords()[1]])
        #expect(flag.isSet)
        #expect(counter.value == 0)
    }

    @Test(arguments: [nil, [TestRecord]()])
    func nothingToImportMarksCompletion(_ legacy: [TestRecord]?) throws {
        let counter = CleanUpCounter()
        let flag = Flag()
        let migrating = MigratingPersistence(base: InMemoryPersistence<String, Tag>(), marker: flag.marker, legacy: { legacy }, cleanUp: { counter.increment() })

        #expect(try migrating.load().isEmpty)
        #expect(counter.value == 0)
        #expect(flag.isSet)
    }

    @Test func keepsLegacyDataWhenSavingTheImportFails() {
        let base = ScriptedPersistence<String, Tag>()
        base.failSaves(1)
        let counter = CleanUpCounter()
        let flag = Flag()
        let migrating = MigratingPersistence(base: base, marker: flag.marker, legacy: { sampleRecords() }, cleanUp: { counter.increment() })

        #expect(throws: PersistenceError.self) { try migrating.load() }
        #expect(counter.value == 0)
        #expect(!flag.isSet)
    }

    @Test func failedLegacyReadsLeaveTheMarkerUnset() {
        let flag = Flag()
        let migrating = MigratingPersistence(
            base: InMemoryPersistence<String, Tag>(),
            marker: flag.marker,
            legacy: { () throws(PersistenceError) -> [TestRecord]? in throw PersistenceError(.readFailed) }
        )

        #expect(throws: PersistenceError.self) { try migrating.load() }
        #expect(!flag.isSet)
    }

    @Test func markersCanRelyOnTheCleanUpAlone() throws {
        let remains = Atomic(true)
        let migrating = MigratingPersistence(
            base: InMemoryPersistence<String, Tag>(),
            marker: MigrationMarker(isComplete: { !remains.load(ordering: .relaxed) }, markComplete: {}),
            legacy: { sampleRecords() },
            cleanUp: { remains.store(false, ordering: .relaxed) }
        )

        #expect(try migrating.load() == sampleRecords())
        try migrating.save([])

        #expect(try migrating.load().isEmpty)
    }

    @Test func savesGoToTheBase() throws {
        let base = InMemoryPersistence<String, Tag>()
        let migrating = MigratingPersistence(base: base, marker: Flag().marker, legacy: { nil })

        try migrating.save(sampleRecords())

        #expect(base.storedRecords == sampleRecords())
    }

    @Test func userDefaultsMarkerPersistsCompletion() {
        let suite = "swift-bookmarks.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let marker = MigrationMarker.userDefaults(key: "migrated", suiteName: suite)

        #expect(!marker.isComplete)
        marker.markComplete()

        #expect(MigrationMarker.userDefaults(key: "migrated", suiteName: suite).isComplete)
    }

    @Test func unavailableDefaultsSuitesNeverReportCompletion() {
        let marker = MigrationMarker.userDefaults(key: "migrated", suiteName: UserDefaults.globalDomain)

        marker.markComplete()

        #expect(!marker.isComplete)
    }

    @Test func standardDefaultsMarker() {
        let key = "swift-bookmarks.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        MigrationMarker.userDefaults(key: key).markComplete()

        #expect(UserDefaults.standard.bool(forKey: key))
    }
}

@Suite("Store errors")
struct StoreErrorTests {
    @Test func exposesBookmarkFailures() {
        #expect(BookmarkStoreError<String>.bookmark(BookmarkError(.missing)).bookmarkFailure == .missing)
        #expect(BookmarkStoreError<String>.notFound("a").bookmarkFailure == nil)
    }

    @Test func everyCaseHasAMessage() {
        let errors: [BookmarkStoreError<String>] = [
            .bookmark(BookmarkError(.denied)), .duplicate(of: "a"), .notFound("a"), .differentItem("a"),
            .persistence(PersistenceError(.writeFailed)),
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func persistenceErrorsDescribeThemselves() {
        let error = PersistenceError(.unsupportedSchemaVersion(4), underlying: CocoaError(.fileReadCorruptFile))

        #expect(error.description.contains("unsupportedSchemaVersion(4)"))
        #expect(error.errorDescription?.contains("newer") == true)
        for reason in [PersistenceError.Reason.unreadable, .readFailed, .writeFailed] {
            #expect(PersistenceError(reason).errorDescription?.isEmpty == false)
        }
    }

}


struct Unencodable: Codable, Sendable {
    struct Refusal: Error {}

    init() {}

    init(from decoder: any Decoder) throws {}

    func encode(to encoder: any Encoder) throws {
        throw Refusal()
    }
}
