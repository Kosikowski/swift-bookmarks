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
        let rewritten = try Envelope.decode(Envelope.encode(stored.records, over: stored, pretty: false))

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

extension PersistedEnvelopeTests {
    /// The records array of `data`, as JSON objects.
    func objects(_ data: Data) throws -> [[String: Any]] {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["records"] as? [[String: Any]])
    }

    func envelope(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": records])
    }

    @Test func unknownFieldsOfReadableRecordsSurviveARewrite() throws {
        var records = try objects(Envelope.encode(sampleRecords(), pretty: false))
        records[0]["pinned"] = true
        records[0]["labels"] = ["red", "blue"]
        let stored = try Envelope.decode(envelope(records))
        var changed = stored.records
        changed[0].lastKnownPath = "/Users/me/Moved"

        let rewritten = try objects(Envelope.encode(changed, over: stored, pretty: false))

        #expect(stored.records == sampleRecords())
        #expect(rewritten[0]["pinned"] as? Bool == true)
        #expect(rewritten[0]["labels"] as? [String] == ["red", "blue"])
        #expect(rewritten[0]["lastKnownPath"] as? String == "/Users/me/Moved")
        #expect(rewritten[1]["pinned"] == nil)
    }

    @Test func unknownFieldsFollowTheirRecordsKey() throws {
        var records = try objects(Envelope.encode(sampleRecords(), pretty: false))
        records[1]["pinned"] = true
        let stored = try Envelope.decode(envelope(records))

        let reordered = try objects(Envelope.encode(stored.records.reversed(), over: stored, pretty: false))
        let withoutB = try objects(Envelope.encode([stored.records[0]], over: stored, pretty: false))

        #expect(reordered.map { $0["key"] as? String } == ["b", "a"])
        #expect(reordered[0]["pinned"] as? Bool == true)
        #expect(withoutB.count == 1)
        #expect(withoutB[0]["pinned"] == nil)
    }

    @Test func knownFieldsTheRecordNoLongerHasAreNotResurrected() throws {
        let stored = try Envelope.decode(Envelope.encode(sampleRecords(), pretty: false))
        var changed = stored.records
        changed[0].refreshedAt = nil
        changed[0].fileIdentity = nil

        let rewritten = try objects(Envelope.encode(changed, over: stored, pretty: false))

        #expect(rewritten[0]["refreshedAt"] == nil)
        #expect(rewritten[0]["fileIdentity"] == nil)
    }

    @Test func aReadableRecordReplacesAnUnreadableOneWithTheSameKey() throws {
        var records = try objects(Envelope.encode([sampleRecords()[0]], pretty: false))
        records.append(["key": "b", "kind": "futureKind"])
        records.append(["key": "c", "kind": "futureKind"])
        let stored = try Envelope.decode(envelope(records))

        let rewritten = try objects(Envelope.encode(sampleRecords(), over: stored, pretty: false))

        #expect(stored.preserved.count == 2)
        #expect(rewritten.map { $0["key"] as? String } == ["a", "b", "c"])
        #expect(rewritten[1]["kind"] as? String == "reference")
    }

    @Test func unreadableRecordsAreWrittenAfterTheReadableOnes() throws {
        var records = try objects(Envelope.encode(sampleRecords(), pretty: false))
        records.insert(["key": "x", "kind": "futureKind"], at: 0)
        let stored = try Envelope.decode(envelope(records))

        let rewritten = try objects(Envelope.encode(stored.records, over: stored, pretty: false))

        #expect(rewritten.map { $0["key"] as? String } == ["a", "b", "x"])
    }

    @Test(arguments: [
        ("null", JSONValue.null),
        ("true", .bool(true)),
        ("false", .bool(false)),
        ("0", .int(0)),
        ("1", .int(1)),
        ("-1", .int(-1)),
        ("-9223372036854775808", .int(.min)),
        ("9223372036854775807", .int(.max)),
        ("9223372036854775808", .unsigned(9_223_372_036_854_775_808)),
        ("18446744073709551615", .unsigned(.max)),
        ("1.5", .double(1.5)),
        ("-0.25", .double(-0.25)),
        ("\"text\"", .string("text")),
        ("\"\"", .string("")),
        ("[]", .array([])),
        ("{}", .object([:])),
        ("[1, [true, null], {\"a\": \"b\"}]", .array([.int(1), .array([.bool(true), .null]), .object(["a": .string("b")])])),
    ])
    func preservesEveryKindOfValue(_ json: String, _ expected: JSONValue) throws {
        let data = Data(#"{"schemaVersion": 1, "records": [{"key": "x", "value": \#(json)}]}"#.utf8)

        let stored = try Envelope.decode(data)
        let rewritten = try Envelope.decode(Envelope.encode([], over: stored, pretty: false))

        #expect(stored.preserved == [.object(["key": .string("x"), "value": expected])])
        #expect(rewritten.preserved == stored.preserved)
    }

    @Test func wholeNumbersWrittenWithAFractionKeepTheirValue() throws {
        let data = Data(#"{"schemaVersion": 1, "records": [{"key": "x", "value": 2.0}]}"#.utf8)

        let stored = try Envelope.decode(data)

        // JSON doesn't distinguish 2.0 from 2, so only the value is kept.
        #expect(stored.preserved == [.object(["key": .string("x"), "value": .int(2)])])
    }

    @Test func numbersBeyondEveryIntegerTypeKeepTheirMagnitude() throws {
        let data = Data(#"{"schemaVersion": 1, "records": [{"key": "x", "value": 1e300}, {"key": "y", "value": -18446744073709551616}]}"#.utf8)

        let stored = try Envelope.decode(data)

        #expect(stored.preserved == [
            .object(["key": .string("x"), "value": .double(1e300)]),
            .object(["key": .string("y"), "value": .double(-18_446_744_073_709_551_616)]),
        ])
    }

    @Test(arguments: [
        #"{"state": "quarantined"}"#,
        #""available""#,
        #"{"state": 3}"#,
        #"{"state": "unavailable", "failure": {"code": "denied"}}"#,
    ])
    func statusesThisVersionCantReadDecodeAsUnknown(_ status: String) throws {
        var records = try objects(Envelope.encode([sampleRecords()[0]], pretty: false))
        records[0]["status"] = try JSONSerialization.jsonObject(with: Data(status.utf8), options: .fragmentsAllowed)

        let stored = try Envelope.decode(envelope(records))

        #expect(stored.records.map(\.status) == [.unknown])
        #expect(stored.preserved.isEmpty)
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

    @Test func aSaveNeverOverwritesDataFromANewerVersion() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let newer = Data(#"{"schemaVersion": 7, "records": []}"#.utf8)
        defaults.set(newer, forKey: "bookmarks")

        let error = #expect(throws: PersistenceError.self) { try persistence().save(sampleRecords()) }

        #expect(error?.reason == .unsupportedSchemaVersion(7))
        #expect(defaults.data(forKey: "bookmarks") == newer)
    }

    @Test func aSaveThatFailsOnUnreadableDataLeavesItAlone() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("a string", forKey: "bookmarks")

        let error = #expect(throws: PersistenceError.self) { try persistence(.fail).save(sampleRecords()) }

        #expect(error?.reason == .unreadable)
        #expect(defaults.string(forKey: "bookmarks") == "a string")
        #expect(defaults.object(forKey: "bookmarks.corrupted") == nil)
    }

    @Test func aLaterCorruptionReplacesTheEarlierBackup() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("first".utf8), forKey: "bookmarks")
        _ = try persistence().load()
        defaults.set(Data("second".utf8), forKey: "bookmarks")

        _ = try persistence().load()

        #expect(defaults.data(forKey: "bookmarks.corrupted") == Data("second".utf8))
    }

    @Test func unknownFieldsSurviveASave() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try persistence().save(sampleRecords())
        let data = try #require(defaults.data(forKey: "bookmarks"))
        let text = try #require(String(data: data, encoding: .utf8))
        defaults.set(Data(text.replacingOccurrences(of: #""key":"a""#, with: #""key":"a","pinned":true"#).utf8), forKey: "bookmarks")

        try persistence().update { records in records.map { var record = $0; record.lastKnownPath += "2"; return record } }

        let savedData = try #require(defaults.data(forKey: "bookmarks"))
        let saved = try #require(String(data: savedData, encoding: .utf8))
        #expect(saved.contains(#""pinned":true"#))
        #expect(try persistence().load().map(\.lastKnownPath) == ["/Users/me/A2", "/Volumes/Backup/B2"])
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
        // Observe before the other process writes, so its write can't come first.
        let changes = persistence().changes()
        let following = Task { await store.reload(on: changes) }
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
        #expect(try PersistedEnvelope<String, Tag>.decode(Data(contentsOf: fileURL)).records == sampleRecords())
    }

    @Test func recoveredRecordsSurviveTheNextChange() throws {
        defer { cleanUp() }
        let persistence = persistence()
        let records = sampleRecords()
        try persistence.save(records)
        try persistence.save(records)
        try Data("garbage".utf8).write(to: fileURL)
        _ = try persistence.load()

        var seen: [TestRecord] = []
        try persistence.update { stored in
            seen = stored
            return Array(stored.dropLast())
        }

        #expect(seen == records)
        #expect(try persistence.load() == [records[0]])
    }

    @Test func anUpdateRecoversTheLastGoodCopyOfACorruptFile() throws {
        defer { cleanUp() }
        let persistence = persistence()
        let records = sampleRecords()
        try persistence.save(records)
        try persistence.save(records)
        try Data("garbage".utf8).write(to: fileURL)

        var seen: [TestRecord] = []
        try persistence.update { seen = $0; return nil }

        #expect(seen == records)
        #expect(try persistence.load() == records)
    }

    @Test func aStoreKeepsRecoveredRecordsWhenItChanges() async throws {
        defer { cleanUp() }
        let records = sampleRecords()
        try persistence().save(records)
        try persistence().save(records)
        try Data("garbage".utf8).write(to: fileURL)
        let store = TestStore(persistence: persistence(), service: Fixtures.service(Fixtures.engine()))

        #expect(try await store.keys() == ["a", "b"])
        try await store.updateMetadata("a") { $0.name = "Renamed" }

        #expect(try await store.keys() == ["a", "b"])
        #expect(try persistence().load().map(\.key) == ["a", "b"])
        #expect(try persistence().load().first?.metadata.name == "Renamed")
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

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    func quarantined() -> [String] {
        files().filter { $0.hasPrefix("bookmarks.json.corrupt-") }
    }

    @Test func aSaveNeverOverwritesAFileFromANewerVersion() throws {
        defer { cleanUp() }
        let newer = #"{"schemaVersion": 3, "records": []}"#
        try write(newer)

        let error = #expect(throws: PersistenceError.self) { try persistence().save(sampleRecords()) }

        #expect(error?.reason == .unsupportedSchemaVersion(3))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == newer)
        #expect(files() == ["bookmarks.json"])
    }

    @Test func aSaveThatFailsOnACorruptFileLeavesItAlone() throws {
        defer { cleanUp() }
        try write("garbage")

        let error = #expect(throws: PersistenceError.self) { try persistence(.fail).save(sampleRecords()) }

        #expect(error?.reason == .unreadable)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "garbage")
        #expect(files() == ["bookmarks.json"])
    }

    @Test(.disabled(if: getuid() == 0, "File permissions don't restrict root"))
    func aSaveReportsAFileItCantReadInsteadOfReplacingIt() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
            cleanUp()
        }
        try persistence().save(sampleRecords())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path(percentEncoded: false))

        let error = #expect(throws: PersistenceError.self) { try persistence().save([]) }

        #expect(error?.reason == .readFailed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
        #expect(try persistence().load() == sampleRecords())
    }

    @Test(.disabled(if: getuid() == 0, "File permissions don't restrict root"))
    func aQuarantineThatFailsKeepsTheCorruptBytes() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.deletingLastPathComponent().path(percentEncoded: false))
            cleanUp()
        }
        try write("garbage")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fileURL.deletingLastPathComponent().path(percentEncoded: false))

        let loadError = #expect(throws: PersistenceError.self) { try persistence().load() }
        let saveError = #expect(throws: PersistenceError.self) { try persistence().save(sampleRecords()) }

        #expect(loadError?.reason == .writeFailed)
        #expect(saveError?.reason == .writeFailed)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "garbage")
        #expect(files() == ["bookmarks.json"])
    }

    @Test func everyCorruptionKeepsItsOwnCopy() throws {
        defer { cleanUp() }
        try write("first")
        _ = try persistence().load()
        try write("second")
        _ = try persistence().load()

        let copies = try quarantined().map {
            try String(contentsOf: fileURL.deletingLastPathComponent().appending(path: $0), encoding: .utf8)
        }

        #expect(Set(copies) == ["first", "second"])
    }

    @Test func aCorruptFileWithoutAGoodCopyIsMovedAside() throws {
        defer { cleanUp() }
        try write("garbage")

        #expect(try persistence().load().isEmpty)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        #expect(quarantined().count == 1)
    }

    @Test func anEmptyFileIsQuarantined() throws {
        defer { cleanUp() }
        try write("")

        #expect(try persistence().load().isEmpty)

        #expect(quarantined().count == 1)
    }

    @Test func theLastGoodCopyNeverHoldsCorruptBytes() throws {
        defer { cleanUp() }
        let persistence = persistence()
        try persistence.save(sampleRecords())
        try persistence.save(sampleRecords())
        try write("garbage")

        try persistence.save([sampleRecords()[0]])

        let lastGood = try PersistedEnvelope<String, Tag>.decode(Data(contentsOf: persistence.lastGoodURL)).records
        #expect(lastGood == sampleRecords())
        #expect(try persistence.load() == [sampleRecords()[0]])
    }

    @Test func aLastGoodCopyThatCantBeWrittenDoesntFailTheSave() throws {
        defer { cleanUp() }
        let persistence = persistence()
        try persistence.save(sampleRecords())
        // A folder in the copy's place makes writing it fail.
        try FileManager.default.createDirectory(at: persistence.lastGoodURL.appending(path: "Blocker"), withIntermediateDirectories: true)

        try persistence.save([sampleRecords()[1]])

        #expect(try persistence.load() == [sampleRecords()[1]])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: persistence.lastGoodURL.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func eachSaveKeepsTheVersionBeforeIt() throws {
        defer { cleanUp() }
        let persistence = persistence()
        try persistence.save([sampleRecords()[0]])
        try persistence.save([sampleRecords()[1]])

        try persistence.save([])

        let lastGood = try PersistedEnvelope<String, Tag>.decode(Data(contentsOf: persistence.lastGoodURL)).records
        #expect(lastGood == [sampleRecords()[1]])
    }

    @Test func anUpdateThatReturnsNothingKeepsTheLastGoodCopy() throws {
        defer { cleanUp() }
        let persistence = persistence()
        try persistence.save(sampleRecords())
        try persistence.save([])
        let before = try Data(contentsOf: persistence.lastGoodURL)

        try persistence.update { _ in nil }

        #expect(try Data(contentsOf: persistence.lastGoodURL) == before)
    }

    @Test(arguments: ["garbage", #"{"schemaVersion": 9, "records": []}"#])
    func aLastGoodCopyThatCantBeReadStartsEmpty(_ lastGood: String) throws {
        defer { cleanUp() }
        let persistence = persistence()
        try write("garbage")
        try Data(lastGood.utf8).write(to: persistence.lastGoodURL)

        #expect(try persistence.load().isEmpty)

        #expect(quarantined().count == 1)
    }

    @Test func aLastGoodCopyIsIgnoredWhenNotKept() throws {
        defer { cleanUp() }
        try persistence().save(sampleRecords())
        try persistence().save(sampleRecords())
        try write("garbage")

        #expect(try persistence(keepsLastGoodCopy: false).load().isEmpty)
    }

    @Test func unknownFieldsSurviveAStoreChange() async throws {
        defer { cleanUp() }
        try persistence().save(sampleRecords())
        let text = try String(contentsOf: fileURL, encoding: .utf8)
            .replacingOccurrences(of: #""key" : "a","#, with: #""key" : "a", "pinned" : true,"#)
        try Data(text.utf8).write(to: fileURL)
        let store = TestStore(persistence: persistence(), service: Fixtures.service(Fixtures.engine()))

        try await store.updateMetadata("a") { $0.name = "Renamed" }

        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(saved.contains(#""pinned" : true"#))
        #expect(saved.contains("Renamed"))
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

    @Test(arguments: [true, false])
    func storesRecordStateWhenItsBaseDoes(_ storesRecordState: Bool) {
        let base = ScriptedPersistence<String, Tag>(storesRecordState: storesRecordState)
        let migrating = MigratingPersistence(base: base, marker: Flag().marker, legacy: { nil })

        #expect(migrating.storesRecordState == storesRecordState)
    }

    @Test func completedMigrationsDoNotResurrectDeletedRecords() throws {
        let flag = Flag()
        let migrating = MigratingPersistence(base: InMemoryPersistence<String, Tag>(), marker: flag.marker, legacy: { sampleRecords() })

        #expect(try migrating.load() == sampleRecords())
        try migrating.save([])

        #expect(try migrating.load().isEmpty)
    }

    @Test func existingRecordsSupersedeAndCleanUpTheLegacyData() throws {
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
        #expect(counter.value == 1)

        _ = try migrating.load()
        #expect(counter.value == 1)
    }

    @Test func aCleanUpThatDidntRunAfterAnImportRunsNextTime() throws {
        let remains = Atomic(true)
        let base = InMemoryPersistence(records: sampleRecords())
        let migrating = MigratingPersistence(
            base: base,
            marker: MigrationMarker(isComplete: { !remains.load(ordering: .relaxed) }, markComplete: {}),
            legacy: { sampleRecords() },
            cleanUp: { remains.store(false, ordering: .relaxed) }
        )

        #expect(try migrating.load() == sampleRecords())

        let stillRemains = remains.load(ordering: .relaxed)
        #expect(!stillRemains)
        #expect(base.saveCount == 0)
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

    @Test func anUpdateBeforeAnyLoadRunsTheMigrationFirst() throws {
        let base = InMemoryPersistence<String, Tag>()
        let counter = CleanUpCounter()
        let flag = Flag()
        let migrating = MigratingPersistence(base: base, marker: flag.marker, legacy: { sampleRecords() }, cleanUp: { counter.increment() })

        var seen: [TestRecord] = []
        try migrating.update { seen = $0; return Array($0.dropFirst()) }

        #expect(seen == sampleRecords())
        #expect(base.storedRecords == [sampleRecords()[1]])
        #expect(counter.value == 1)
        #expect(flag.isSet)
    }

    @Test func aFailedLegacyReadFailsTheUpdateWithoutWriting() {
        let base = ScriptedPersistence<String, Tag>()
        let flag = Flag()
        let migrating = MigratingPersistence(
            base: base,
            marker: flag.marker,
            legacy: { () throws(PersistenceError) -> [TestRecord]? in throw PersistenceError(.readFailed) }
        )
        var called = false

        let error = #expect(throws: PersistenceError.self) { try migrating.update { called = true; return $0 } }

        #expect(error?.reason == .readFailed)
        #expect(!called)
        #expect(base.updateCount == 0)
        #expect(!flag.isSet)
    }

    @Test func updatesAfterTheMigrationNeverReadTheLegacyDataAgain() throws {
        let reads = CleanUpCounter()
        let migrating = MigratingPersistence(
            base: InMemoryPersistence<String, Tag>(),
            marker: Flag().marker,
            legacy: { reads.increment(); return sampleRecords() }
        )
        _ = try migrating.load()

        try migrating.update { _ in [] }
        try migrating.update { _ in nil }

        #expect(reads.value == 1)
        #expect(try migrating.load().isEmpty)
    }

    @Test func anImportNeverOverwritesRecordsAnotherWriterSavedMeanwhile() throws {
        let base = ScriptedPersistence<String, Tag>()
        let counter = CleanUpCounter()
        let flag = Flag()
        let other = sampleRecords()[1]
        let migrating = MigratingPersistence(
            base: base,
            marker: flag.marker,
            legacy: {
                // Another process saves between this process's read of the base and its import.
                base.replaceStoredRecords([other])
                return [sampleRecords()[0]]
            },
            cleanUp: { counter.increment() }
        )

        #expect(try migrating.load() == [other])
        #expect(base.storedRecords == [other])
        #expect(counter.value == 1)
        #expect(flag.isSet)
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

@Suite("Default update")
struct DefaultUpdateTests {
    /// A persistence that relies on the protocol's default `update(_:)`.
    struct LoadAndSave: BookmarkPersistence {
        let base = InMemoryPersistence<String, Tag>()

        func load() throws(PersistenceError) -> [TestRecord] { try base.load() }
        func save(_ records: [TestRecord]) throws(PersistenceError) { try base.save(records) }
    }

    @Test func savesWhatTheTransformReturns() throws {
        let persistence = LoadAndSave()
        try persistence.save([sampleRecords()[0]])

        try persistence.update { $0 + [sampleRecords()[1]] }

        #expect(persistence.base.storedRecords == sampleRecords())
        #expect(persistence.base.saveCount == 2)
    }

    @Test func savesNothingWhenTheTransformReturnsNil() throws {
        let persistence = LoadAndSave()
        try persistence.save(sampleRecords())

        try persistence.update { _ in nil }

        #expect(persistence.base.storedRecords == sampleRecords())
        #expect(persistence.base.saveCount == 1)
    }
}

@Suite("Store errors")
struct StoreErrorTests {
    @Test func exposesBookmarkFailures() {
        #expect(BookmarkStoreError<String>.bookmark(BookmarkError(.missing)).bookmarkFailure == .missing)
        #expect(BookmarkStoreError<String>.notFound("a").bookmarkFailure == nil)
    }

    @Test func carryNoTextForUsers() {
        let errors: [any Error] = [BookmarkStoreError<String>.notFound("a"), PersistenceError(.writeFailed)]

        for error in errors {
            #expect(!(error is any LocalizedError))
        }
    }

    @Test func persistenceErrorsDescribeThemselvesForLogs() {
        let error = PersistenceError(.unsupportedSchemaVersion(4), underlying: CocoaError(.fileReadCorruptFile))

        #expect(error.description.contains("unsupportedSchemaVersion(4)"))
        #expect(error.description.contains("underlying"))
        #expect(PersistenceError(.readFailed).description == "PersistenceError(readFailed)")
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
