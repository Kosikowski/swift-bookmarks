import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("ScriptedPersistence")
struct ScriptedPersistenceTests {
    typealias Record = BookmarkRecord<String, NoMetadata>

    static func record(_ key: String) -> Record {
        Record(key: key, data: BookmarkData(Data(key.utf8)), kind: .reference, lastKnownPath: "/\(key)", createdAt: Date(timeIntervalSince1970: 0), metadata: NoMetadata())
    }

    @Test func storesWhatWasSaved() throws {
        let persistence = ScriptedPersistence<String, NoMetadata>(records: [Self.record("a")])

        #expect(try persistence.load().map(\.key) == ["a"])
        try persistence.save([Self.record("b")])

        #expect(persistence.storedRecords.map(\.key) == ["b"])
        #expect(persistence.loadCount == 1)
        #expect(persistence.saveCount == 1)
    }

    @Test func failsTheRequestedNumberOfLoads() throws {
        let persistence = ScriptedPersistence<String, NoMetadata>(records: [Self.record("a")])
        persistence.failLoads(2, reason: .unreadable)

        for _ in 0..<2 {
            let error = #expect(throws: PersistenceError.self) { try persistence.load() }
            #expect(error?.reason == .unreadable)
        }

        #expect(try persistence.load().map(\.key) == ["a"])
        #expect(persistence.loadCount == 3)
    }

    @Test func failedSavesKeepTheStoredRecords() throws {
        let persistence = ScriptedPersistence<String, NoMetadata>(records: [Self.record("a")])
        persistence.failSaves(1)

        let error = #expect(throws: PersistenceError.self) { try persistence.save([]) }
        try persistence.save([Self.record("c")])

        #expect(error?.reason == .writeFailed)
        #expect(persistence.storedRecords.map(\.key) == ["c"])
        #expect(persistence.saveCount == 1)
    }

    @Test func replacingRecordsIsntASave() {
        let persistence = ScriptedPersistence<String, NoMetadata>()

        persistence.replaceStoredRecords([Self.record("x")])

        #expect(persistence.storedRecords.map(\.key) == ["x"])
        #expect(persistence.saveCount == 0)
    }
}
