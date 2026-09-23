@testable import Bookmarks
import Foundation
import Testing

@Suite("RecordTable")
struct RecordTableTests {
    typealias Table = RecordTable<String, Tag>

    static let date = Date(timeIntervalSince1970: 1_000)

    static func record(
        _ key: String,
        data: String? = nil,
        path: String? = nil,
        identity: FileIdentity? = nil,
        status: RecordStatus = .available,
        tag: String? = nil
    ) -> TestRecord {
        TestRecord(
            key: key,
            data: BookmarkData(Data((data ?? key).utf8)),
            kind: .appScoped(.readWrite),
            lastKnownPath: path ?? "/\(key)",
            fileIdentity: identity,
            status: status,
            createdAt: date,
            metadata: Tag(name: tag ?? key)
        )
    }

    static func resolution(of data: String, path: String = "/moved", refreshed: String? = nil, identity: FileIdentity? = nil) -> Table.Resolution {
        Table.Resolution(
            originalData: BookmarkData(Data(data.utf8)),
            refreshedData: refreshed.map { BookmarkData(Data($0.utf8)) },
            path: path,
            identity: identity,
            date: date.addingTimeInterval(60)
        )
    }

    @Test func loadingKeepsTheFirstRecordForEachKey() {
        let table = Table([Self.record("a"), Self.record("b"), Self.record("a", data: "other")])

        #expect(table.order == ["a", "b"])
        #expect(table["a"]?.data == BookmarkData(Data("a".utf8)))
    }

    @Suite("Adding")
    struct Adding {
        @Test func newKeysAreAppendedAndReportedAsAdded() {
            var table = Table([RecordTableTests.record("a")])

            let change = table.put(RecordTableTests.record("b"), ordering: .insertion)
            let invalidated = table.takeInvalidated()

            #expect(change == .added("b"))
            #expect(table.order == ["a", "b"])
            #expect(invalidated == ["b"])
        }

        @Test func existingKeysKeepTheirPlaceAndAreReportedAsUpdated() {
            var table = Table([RecordTableTests.record("a"), RecordTableTests.record("b")])

            let change = table.put(RecordTableTests.record("a", data: "new"), ordering: .insertion)

            #expect(change == .updated("a"))
            #expect(table.order == ["a", "b"])
            #expect(table["a"]?.data == BookmarkData(Data("new".utf8)))
        }

        @Test func mostRecentlyUsedOrderingPutsNewRecordsFirst() {
            var table = Table([RecordTableTests.record("a")])

            _ = table.put(RecordTableTests.record("b"), ordering: .mostRecentlyUsed)

            #expect(table.order == ["b", "a"])
        }

        @Test func evictsTheLastRecordsButNeverTheKeptOne() {
            var table = Table(["a", "b", "c"].map { RecordTableTests.record($0) })

            let evicted = table.evict(beyond: 1, keeping: "c")
            let unlimited = table.evict(beyond: nil, keeping: "c")
            let invalidated = table.takeInvalidated()

            #expect(evicted == ["b", "a"])
            #expect(unlimited.isEmpty)
            #expect(table.order == ["c"])
            #expect(invalidated == ["a", "b"])
        }
    }

    @Suite("Finding records")
    struct Finding {
        let identity = FileIdentity(volumeUUID: "V", fileID: 1)

        @Test func duplicatesMatchByIdentityWhenBothHaveOne() {
            let table = Table([RecordTableTests.record("a", path: "/old", identity: identity)])

            #expect(table.duplicate(of: identity, path: "/elsewhere", excluding: "b")?.key == "a")
            #expect(table.duplicate(of: FileIdentity(volumeUUID: "V", fileID: 2), path: "/old", excluding: "b") == nil)
            #expect(table.duplicate(of: identity, path: "/old", excluding: "a") == nil)
        }

        @Test func duplicatesFallBackToThePath() {
            let table = Table([RecordTableTests.record("a", path: "/old")])

            #expect(table.duplicate(of: identity, path: "/old", excluding: "b")?.key == "a")
            #expect(table.duplicate(of: nil, path: "/new", excluding: "b") == nil)
        }

        @Test func keysMatchByIdentityFirstThenByPath() {
            let table = Table([
                RecordTableTests.record("byPath", path: "/shared"),
                RecordTableTests.record("byIdentity", path: "/other", identity: identity),
            ])

            #expect(table.key(matching: identity, path: NormalizedPath("/shared")) == "byIdentity")
            #expect(table.key(matching: nil, path: NormalizedPath("/shared/")) == "byPath")
            #expect(table.key(matching: nil, path: NormalizedPath("/nothing")) == nil)
        }

        @Test func containingKeysAreDeepestFirst() {
            let table = Table([
                RecordTableTests.record("home", path: "/Users/me"),
                RecordTableTests.record("elsewhere", path: "/Users/other"),
                RecordTableTests.record("projects", path: "/Users/me/Projects"),
            ])

            #expect(table.keysContaining(NormalizedPath("/Users/me/Projects/App")) == ["projects", "home"])
        }

        @Test func pathsExcludeTheGivenKey() {
            let table = Table([RecordTableTests.record("a"), RecordTableTests.record("b")])

            #expect(table.paths(excluding: "a") == ["/b"])
        }
    }

    @Suite("Changing records")
    struct Changing {
        @Test func replacingAnItemKeepsTheKnownIdentityWhenTheNewOneIsUnknown() throws {
            let identity = FileIdentity(volumeUUID: "V", fileID: 1)
            var table = Table([RecordTableTests.record("a", identity: identity, status: .unavailable(.missing, since: RecordTableTests.date))])

            let replaced = table.replaceItem(
                of: "a",
                data: BookmarkData(Data("new".utf8)),
                kind: .reference,
                path: "/new",
                identity: nil,
                date: RecordTableTests.date,
                ordering: .insertion
            )
            let invalidated = table.takeInvalidated()

            let record = try #require(replaced)
            #expect(record.fileIdentity == identity)
            #expect(record.status == .available)
            #expect(record.kind == .reference)
            #expect(record.refreshedAt == RecordTableTests.date)
            #expect(invalidated == ["a"])
        }

        @Test func replacingAnUnknownKeyDoesNothing() {
            var table = Table()

            let replaced = table.replaceItem(of: "a", data: BookmarkData(Data()), kind: .reference, path: "/", identity: nil, date: RecordTableTests.date, ordering: .insertion)
            let invalidated = table.takeInvalidated()

            #expect(replaced == nil)
            #expect(invalidated.isEmpty)
        }

        @Test func metadataChangesDontInvalidate() {
            var table = Table([RecordTableTests.record("a")])

            let updatedKnown = table.updateMetadata(of: "a") { $0.name = "renamed" }
            let updatedUnknown = table.updateMetadata(of: "missing") { $0.name = "x" }
            let invalidated = table.takeInvalidated()

            #expect(updatedKnown)
            #expect(!updatedUnknown)
            #expect(table["a"]?.metadata.name == "renamed")
            #expect(invalidated.isEmpty)
        }

        @Test func removingReportsWhetherAnythingWasThere() {
            var table = Table([RecordTableTests.record("a"), RecordTableTests.record("b")])

            let first = table.remove("a")
            let second = table.remove("a")
            let rest = table.removeAll()

            #expect(first)
            #expect(!second)
            #expect(rest == ["b"])
            #expect(table.orderedRecords.isEmpty)
        }

        @Test func movingClampsTheIndex() {
            var table = Table(["a", "b", "c"].map { RecordTableTests.record($0) })

            let movedPastTheEnd = table.move("a", to: 10)
            let orderAfterFirstMove = table.order
            let movedBeforeTheStart = table.move("a", to: -3)
            let movedUnknown = table.move("missing", to: 0)

            #expect(movedPastTheEnd && movedBeforeTheStart && !movedUnknown)
            #expect(orderAfterFirstMove == ["b", "c", "a"])
            #expect(table.order == ["a", "b", "c"])
        }

        @Test func promotingOnlyMovesForRecentsOrdering() {
            var table = Table(["a", "b"].map { RecordTableTests.record($0) })

            let withInsertionOrder = table.promote("b", ordering: .insertion)
            let withRecentsOrder = table.promote("b", ordering: .mostRecentlyUsed)
            let whenAlreadyFirst = table.promote("b", ordering: .mostRecentlyUsed)
            let whenUnknown = table.promote("missing", ordering: .mostRecentlyUsed)

            #expect(!withInsertionOrder && withRecentsOrder && !whenAlreadyFirst && !whenUnknown)
            #expect(table.order == ["b", "a"])
        }
    }

    @Suite("Resolution results")
    struct Results {
        @Test func successIsSupersededOnceTheRecordChanges() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))
            _ = table.put(RecordTableTests.record("a", data: "regranted"), ordering: .insertion)

            let outcome = table.applySuccess(RecordTableTests.resolution(of: "a"), to: snapshot)

            #expect(!table.isCurrent(snapshot))
            #expect(outcome == .superseded)
            #expect(table["a"]?.lastKnownPath == "/a")
        }

        @Test func successIsSupersededForOtherBytes() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))

            let outcome = table.applySuccess(RecordTableTests.resolution(of: "other"), to: snapshot)

            #expect(outcome == .superseded)
        }

        @Test func successIsSupersededOnceTheRecordIsGone() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))
            _ = table.remove("a")

            let outcome = table.applySuccess(RecordTableTests.resolution(of: "a"), to: snapshot)

            #expect(outcome == .superseded)
        }

        @Test func unchangedResultsReportNoChange() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))

            let outcome = table.applySuccess(RecordTableTests.resolution(of: "a", path: "/a"), to: snapshot)

            #expect(outcome == .unchanged)
        }

        @Test func successStoresRefreshedBytesPathAndIdentity() throws {
            let identity = FileIdentity(volumeUUID: "V", fileID: 9)
            var table = Table([RecordTableTests.record("a", status: .unavailable(.missing, since: RecordTableTests.date))])
            let snapshot = try #require(table.snapshot("a"))

            let outcome = table.applySuccess(RecordTableTests.resolution(of: "a", refreshed: "fresh", identity: identity), to: snapshot)
            let invalidated = table.takeInvalidated()

            let record = try #require(table["a"])
            #expect(outcome == .changed)
            #expect(record.data == BookmarkData(Data("fresh".utf8)))
            #expect(record.lastKnownPath == "/moved")
            #expect(record.fileIdentity == identity)
            #expect(record.status == .available)
            #expect(record.refreshedAt == RecordTableTests.date.addingTimeInterval(60))
            #expect(invalidated.isEmpty)
        }

        @Test func failuresMarkTheRecordOnce() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))

            let first = table.applyFailure(.missing, to: snapshot, dropping: false, at: RecordTableTests.date)
            let repeated = table.applyFailure(.missing, to: snapshot, dropping: false, at: RecordTableTests.date.addingTimeInterval(1))
            let statusAfterRepeat = table["a"]?.status
            let different = table.applyFailure(.denied, to: snapshot, dropping: false, at: RecordTableTests.date)

            #expect(first == .updated("a"))
            #expect(repeated == nil)
            #expect(statusAfterRepeat == .unavailable(.missing, since: RecordTableTests.date))
            #expect(different == .updated("a"))
        }

        @Test func failuresCanDropTheRecord() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))

            let change = table.applyFailure(.missing, to: snapshot, dropping: true, at: RecordTableTests.date)

            #expect(change == .removed("a"))
            #expect(table["a"] == nil)
        }

        @Test func failuresForSupersededSnapshotsAreIgnored() throws {
            var table = Table([RecordTableTests.record("a")])
            let snapshot = try #require(table.snapshot("a"))
            _ = table.remove("a")
            _ = table.put(RecordTableTests.record("a"), ordering: .insertion)

            let change = table.applyFailure(.missing, to: snapshot, dropping: true, at: RecordTableTests.date)

            #expect(change == nil)
            #expect(table["a"] != nil)
        }
    }

    @Suite("Reloading")
    struct Reloading {
        @Test func reportsAddedRemovedAndUpdatedRecords() {
            var table = Table([
                RecordTableTests.record("kept"),
                RecordTableTests.record("removed"),
                RecordTableTests.record("rebookmarked"),
                RecordTableTests.record("retagged"),
                RecordTableTests.record("marked"),
            ])

            let changes = table.replaceAll(with: [
                RecordTableTests.record("added"),
                RecordTableTests.record("kept"),
                RecordTableTests.record("rebookmarked", data: "new"),
                RecordTableTests.record("retagged", tag: "new tag"),
                RecordTableTests.record("marked", status: .unavailable(.denied, since: RecordTableTests.date)),
            ])
            let invalidated = table.takeInvalidated()

            #expect(changes == [.removed("removed"), .added("added"), .updated("rebookmarked"), .updated("retagged"), .updated("marked")])
            #expect(table.order == ["added", "kept", "rebookmarked", "retagged", "marked"])
            #expect(invalidated == ["removed", "added", "rebookmarked"])
        }

        @Test func metadataThatCantBeEncodedCountsAsChanged() {
            let record = BookmarkRecord(key: "a", data: BookmarkData(Data()), kind: .reference, lastKnownPath: "/a", createdAt: RecordTableTests.date, metadata: Unencodable())
            var table = RecordTable<String, Unencodable>([record])

            let changes = table.replaceAll(with: [record])

            #expect(changes == [.updated("a")])
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
