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

    static func table(_ keys: String...) -> Table {
        Table(keys.map { record($0) })
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

    struct Transaction<Result> {
        let result: Result
        let changes: [String]
        let invalidated: Set<String>
    }

    static func transaction<Result>(_ table: inout Table, _ body: (inout Table) -> Result) -> Transaction<Result> {
        let old = table
        let result = body(&table)
        let (changes, invalidated) = table.takeChanges(since: old)
        return Transaction(result: result, changes: changes.map(\.summary), invalidated: invalidated)
    }

    @Test func loadingKeepsTheFirstRecordForEachKey() {
        let table = Table([Self.record("a"), Self.record("b"), Self.record("a", data: "other")])

        #expect(table.order == ["a", "b"])
        #expect(table["a"]?.data == BookmarkData(Data("a".utf8)))
    }

    @Test func transactionsWithoutChangesReportNothing() {
        var table = Self.table("a")

        let transaction = Self.transaction(&table) { _ in }

        #expect(transaction.changes.isEmpty)
        #expect(transaction.invalidated.isEmpty)
    }

    @Test func changesCarryTheCurrentRecords() {
        var table = Self.table("a")

        let old = table
        _ = table.updateMetadata(of: "a") { $0.name = "renamed" }
        let (changes, _) = table.takeChanges(since: old)

        guard case .updated(let record)? = changes.first else {
            Issue.record("Expected an update, got \(changes)")
            return
        }
        #expect(record.metadata.name == "renamed")
    }

    @Suite("Adding")
    struct Adding {
        @Test func newKeysAreAppendedAndReportedAsAdded() {
            var table = RecordTableTests.table("a")

            let transaction = RecordTableTests.transaction(&table) { $0.put(RecordTableTests.record("b"), ordering: .insertion) }

            #expect(transaction.changes == ["added b"])
            #expect(transaction.invalidated == ["b"])
            #expect(table.order == ["a", "b"])
        }

        @Test func existingKeysKeepTheirPlaceAndAreReportedAsUpdated() {
            var table = RecordTableTests.table("a", "b")

            let transaction = RecordTableTests.transaction(&table) { $0.put(RecordTableTests.record("a", data: "new"), ordering: .insertion) }

            #expect(transaction.changes == ["updated a"])
            #expect(transaction.invalidated == ["a"])
            #expect(table.order == ["a", "b"])
        }

        @Test func mostRecentlyUsedOrderingPutsNewRecordsFirst() {
            var table = RecordTableTests.table("a")

            let transaction = RecordTableTests.transaction(&table) { $0.put(RecordTableTests.record("b"), ordering: .mostRecentlyUsed) }

            #expect(transaction.changes == ["added b", "reordered b,a"])
        }

        @Test func insertionOrderEvictsTheOldestButNeverTheKeptOne() {
            var table = RecordTableTests.table("a", "b", "c")

            let evicting = RecordTableTests.transaction(&table) { $0.evict(beyond: 2, keeping: "c", ordering: .insertion) }
            let unlimited = RecordTableTests.transaction(&table) { $0.evict(beyond: nil, keeping: "c", ordering: .insertion) }

            #expect(evicting.changes == ["removed a"])
            #expect(evicting.invalidated == ["a"])
            #expect(unlimited.changes.isEmpty)
            #expect(table.order == ["b", "c"])
        }

        @Test func mostRecentlyUsedOrderEvictsTheLeastRecentButNeverTheKeptOne() {
            var table = RecordTableTests.table("a", "b", "c")

            let evicting = RecordTableTests.transaction(&table) { $0.evict(beyond: 1, keeping: "c", ordering: .mostRecentlyUsed) }

            #expect(evicting.changes == ["removed a", "removed b"])
            #expect(table.order == ["c"])
        }
    }

    @Suite("Finding records")
    struct Finding {
        let identity = FileIdentity(volumeUUID: "V", fileID: 1)

        @Test func duplicatesMatchByIdentityWhenBothHaveOne() {
            let table = Table([RecordTableTests.record("a", path: "/old", identity: identity)])

            #expect(table.duplicate(of: identity, path: NormalizedPath("/elsewhere"), excluding: "b")?.key == "a")
            #expect(table.duplicate(of: FileIdentity(volumeUUID: "V", fileID: 2), path: NormalizedPath("/old"), excluding: "b") == nil)
            #expect(table.duplicate(of: identity, path: NormalizedPath("/old"), excluding: "a") == nil)
        }

        @Test func duplicatesFallBackToThePath() {
            let table = Table([RecordTableTests.record("a", path: "/old")])

            #expect(table.duplicate(of: identity, path: NormalizedPath("/old"), excluding: "b")?.key == "a")
            #expect(table.duplicate(of: nil, path: NormalizedPath("/new"), excluding: "b") == nil)
        }

        @Test func pathFallbacksFollowTheVolumesCaseRule() {
            let table = Table([RecordTableTests.record("a", path: "/Users/me/Old")])

            #expect(table.duplicate(of: nil, path: NormalizedPath("/users/me/old", isCaseSensitive: false), excluding: "b")?.key == "a")
            #expect(table.duplicate(of: nil, path: NormalizedPath("/users/me/old"), excluding: "b") == nil)
            #expect(table.key(matching: nil, path: NormalizedPath("/USERS/me/OLD", isCaseSensitive: false)) == "a")
            #expect(table.keysContaining(NormalizedPath("/users/me/old/file", isCaseSensitive: false)) == ["a"])
            #expect(table.keysContaining(NormalizedPath("/users/me/old/file")).isEmpty)
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
            let table = RecordTableTests.table("a", "b")

            #expect(table.paths(excluding: "a") == ["/b"])
        }
    }

    @Suite("Changing records")
    struct Changing {
        @Test func replacingAnItemKeepsTheKnownIdentityWhenTheNewOneIsUnknown() throws {
            let identity = FileIdentity(volumeUUID: "V", fileID: 1)
            var table = Table([RecordTableTests.record("a", identity: identity, status: .unavailable(.missing, since: RecordTableTests.date))])

            let transaction = RecordTableTests.transaction(&table) {
                $0.replaceItem(
                    of: "a",
                    data: BookmarkData(Data("new".utf8)),
                    kind: .reference,
                    path: "/new",
                    identity: nil,
                    date: RecordTableTests.date,
                    ordering: .insertion
                )
            }

            let record = try #require(transaction.result)
            #expect(record.fileIdentity == identity)
            #expect(record.status == .available)
            #expect(record.kind == .reference)
            #expect(record.refreshedAt == RecordTableTests.date)
            #expect(transaction.changes == ["updated a"])
            #expect(transaction.invalidated == ["a"])
        }

        @Test func replacingAnUnknownKeyDoesNothing() {
            var table = Table()

            let transaction = RecordTableTests.transaction(&table) {
                $0.replaceItem(of: "a", data: BookmarkData(Data()), kind: .reference, path: "/", identity: nil, date: RecordTableTests.date, ordering: .insertion)
            }

            #expect(transaction.result == nil)
            #expect(transaction.changes.isEmpty)
        }

        @Test func metadataChangesDontInvalidate() {
            var table = RecordTableTests.table("a")

            let known = RecordTableTests.transaction(&table) { $0.updateMetadata(of: "a") { $0.name = "renamed" } }
            let unknown = RecordTableTests.transaction(&table) { $0.updateMetadata(of: "missing") { $0.name = "x" } }

            #expect(known.result && !unknown.result)
            #expect(known.changes == ["updated a"])
            #expect(known.invalidated.isEmpty)
            #expect(unknown.changes.isEmpty)
            #expect(table["a"]?.metadata.name == "renamed")
        }

        @Test func removingReportsWhetherAnythingWasThere() {
            var table = RecordTableTests.table("a", "b", "c")

            let first = RecordTableTests.transaction(&table) { $0.remove("a") }
            let second = RecordTableTests.transaction(&table) { $0.remove("a") }
            let rest = RecordTableTests.transaction(&table) { $0.removeAll() }

            #expect(first.result && !second.result)
            #expect(first.changes == ["removed a"])
            #expect(second.changes.isEmpty)
            #expect(rest.changes == ["removed b", "removed c"])
            #expect(table.orderedRecords.isEmpty)
        }

        @Test func movingClampsTheIndexAndReportsTheNewOrder() {
            var table = RecordTableTests.table("a", "b", "c")

            let pastTheEnd = RecordTableTests.transaction(&table) { $0.move("a", to: 10) }
            let beforeTheStart = RecordTableTests.transaction(&table) { $0.move("a", to: -3) }
            let unknown = RecordTableTests.transaction(&table) { $0.move("missing", to: 0) }

            #expect(pastTheEnd.result && beforeTheStart.result && !unknown.result)
            #expect(pastTheEnd.changes == ["reordered b,c,a"])
            #expect(beforeTheStart.changes == ["reordered a,b,c"])
            #expect(unknown.changes.isEmpty)
        }

        @Test func promotingOnlyMovesForRecentsOrdering() {
            var table = RecordTableTests.table("a", "b")

            let insertion = RecordTableTests.transaction(&table) { $0.promote("b", ordering: .insertion) }
            let recents = RecordTableTests.transaction(&table) { $0.promote("b", ordering: .mostRecentlyUsed) }
            let alreadyFirst = RecordTableTests.transaction(&table) { $0.promote("b", ordering: .mostRecentlyUsed) }
            let unknown = RecordTableTests.transaction(&table) { $0.promote("missing", ordering: .mostRecentlyUsed) }

            #expect(insertion.changes.isEmpty)
            #expect(recents.changes == ["reordered b,a"])
            #expect(alreadyFirst.changes.isEmpty)
            #expect(unknown.changes.isEmpty)
        }
    }

    @Suite("Resolution results")
    struct Results {
        @Test func successIsSupersededOnceTheRecordChanges() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))
            _ = RecordTableTests.transaction(&table) { $0.put(RecordTableTests.record("a", data: "regranted"), ordering: .insertion) }

            let transaction = RecordTableTests.transaction(&table) { $0.applySuccess(RecordTableTests.resolution(of: "a"), to: snapshot) }

            #expect(!table.isCurrent(snapshot))
            #expect(transaction.result == .superseded)
            #expect(transaction.changes.isEmpty)
            #expect(table["a"]?.lastKnownPath == "/a")
        }

        @Test func successIsSupersededForOtherBytes() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))

            let transaction = RecordTableTests.transaction(&table) { $0.applySuccess(RecordTableTests.resolution(of: "other"), to: snapshot) }

            #expect(transaction.result == .superseded)
        }

        @Test func successIsSupersededOnceTheRecordIsGone() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))
            _ = table.remove("a")

            let transaction = RecordTableTests.transaction(&table) { $0.applySuccess(RecordTableTests.resolution(of: "a"), to: snapshot) }

            #expect(transaction.result == .superseded)
        }

        @Test func unchangedResultsReportNoChange() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))

            let transaction = RecordTableTests.transaction(&table) { $0.applySuccess(RecordTableTests.resolution(of: "a", path: "/a"), to: snapshot) }

            #expect(transaction.result == .unchanged)
            #expect(transaction.changes.isEmpty)
        }

        @Test func successStoresRefreshedBytesPathAndIdentity() throws {
            let identity = FileIdentity(volumeUUID: "V", fileID: 9)
            var table = Table([RecordTableTests.record("a", status: .unavailable(.missing, since: RecordTableTests.date))])
            let snapshot = try #require(table.snapshot("a"))

            let transaction = RecordTableTests.transaction(&table) {
                $0.applySuccess(RecordTableTests.resolution(of: "a", refreshed: "fresh", identity: identity), to: snapshot)
            }

            let record = try #require(table["a"])
            #expect(transaction.result == .changed)
            #expect(transaction.changes == ["updated a"])
            #expect(transaction.invalidated.isEmpty)
            #expect(record.data == BookmarkData(Data("fresh".utf8)))
            #expect(record.lastKnownPath == "/moved")
            #expect(record.fileIdentity == identity)
            #expect(record.status == .available)
            #expect(record.refreshedAt == RecordTableTests.date.addingTimeInterval(60))
        }

        @Test func failuresMarkTheRecordOnce() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))

            let first = RecordTableTests.transaction(&table) { $0.applyFailure(.missing, to: snapshot, dropping: false, at: RecordTableTests.date) }
            let repeated = RecordTableTests.transaction(&table) {
                $0.applyFailure(.missing, to: snapshot, dropping: false, at: RecordTableTests.date.addingTimeInterval(1))
            }
            let statusAfterRepeat = table["a"]?.status
            let different = RecordTableTests.transaction(&table) { $0.applyFailure(.denied, to: snapshot, dropping: false, at: RecordTableTests.date) }

            #expect(first.changes == ["updated a"])
            #expect(repeated.changes.isEmpty)
            #expect(statusAfterRepeat == .unavailable(.missing, since: RecordTableTests.date))
            #expect(different.changes == ["updated a"])
        }

        @Test func failuresCanDropTheRecord() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))

            let transaction = RecordTableTests.transaction(&table) { $0.applyFailure(.missing, to: snapshot, dropping: true, at: RecordTableTests.date) }

            #expect(transaction.changes == ["removed a"])
            #expect(table["a"] == nil)
        }

        @Test func failuresForSupersededSnapshotsAreIgnored() throws {
            var table = RecordTableTests.table("a")
            let snapshot = try #require(table.snapshot("a"))
            _ = RecordTableTests.transaction(&table) { table in
                _ = table.remove("a")
                table.put(RecordTableTests.record("a"), ordering: .insertion)
            }

            let transaction = RecordTableTests.transaction(&table) { $0.applyFailure(.missing, to: snapshot, dropping: true, at: RecordTableTests.date) }

            #expect(transaction.changes.isEmpty)
            #expect(table["a"] != nil)
        }
    }

    @Suite("Reloading")
    struct Reloading {
        @Test func reportsAddedRemovedUpdatedAndReorderedRecords() {
            var table = Table([
                RecordTableTests.record("kept"),
                RecordTableTests.record("removed"),
                RecordTableTests.record("rebookmarked"),
                RecordTableTests.record("retagged"),
                RecordTableTests.record("marked"),
            ])

            let transaction = RecordTableTests.transaction(&table) {
                $0.replaceAll(with: [
                    RecordTableTests.record("added"),
                    RecordTableTests.record("kept"),
                    RecordTableTests.record("rebookmarked", data: "new"),
                    RecordTableTests.record("retagged", tag: "new tag"),
                    RecordTableTests.record("marked", status: .unavailable(.denied, since: RecordTableTests.date)),
                ])
            }

            #expect(transaction.changes == [
                "removed removed",
                "added added",
                "updated rebookmarked",
                "updated retagged",
                "updated marked",
                "reordered added,kept,rebookmarked,retagged,marked",
            ])
            #expect(transaction.invalidated == ["removed", "added", "rebookmarked"])
        }

        @Test func identicalRecordsReportNothing() {
            var table = RecordTableTests.table("a", "b")

            let transaction = RecordTableTests.transaction(&table) { $0.replaceAll(with: [RecordTableTests.record("a"), RecordTableTests.record("b")]) }

            #expect(transaction.changes.isEmpty)
        }

        @Test func changedMetadataCountsAsChanged() {
            let record = BookmarkRecord(key: "a", data: BookmarkData(Data()), kind: .reference, lastKnownPath: "/a", createdAt: RecordTableTests.date, metadata: 1)
            var changed = record
            changed.metadata = 2
            var table = RecordTable<String, Int>([record])

            let old = table
            table.replaceAll(with: [changed])
            let (changes, _) = table.takeChanges(since: old)

            #expect(changes.map(\.summary) == ["updated a"])
        }
    }
}
