import Bookmarks
import Foundation
import Testing

@Suite("BookmarkData")
struct BookmarkDataTests {
    @Test func encodesAsASingleBase64Value() throws {
        let data = BookmarkData(Data([1, 2, 3]))

        let json = try JSONEncoder().encode(data)

        #expect(String(decoding: json, as: UTF8.self) == "\"AQID\"")
    }

    @Test func decodesFromABase64Value() throws {
        let decoded = try JSONDecoder().decode(BookmarkData.self, from: Data("\"AQID\"".utf8))

        #expect(decoded.rawValue == Data([1, 2, 3]))
    }

    @Test func keepsBytesUnchangedInsideContainers() throws {
        struct Envelope: Codable, Equatable {
            let bookmark: BookmarkData
        }
        let original = Envelope(bookmark: BookmarkData(Data((0...255).map(UInt8.init))))

        let decoded = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
    }

    @Test func decodesTheSameShapeAsPlainData() throws {
        struct Legacy: Codable { let bookmark: Data }
        struct Current: Codable { let bookmark: BookmarkData }
        let legacy = try JSONEncoder().encode(Legacy(bookmark: Data([9, 8, 7])))

        let current = try JSONDecoder().decode(Current.self, from: legacy)

        #expect(current.bookmark.rawValue == Data([9, 8, 7]))
        #expect(try JSONEncoder().encode(current) == legacy)
    }

    @Test func reportsItsSizeWithoutRevealingContents() {
        let data = BookmarkData(Data(repeating: 0xAB, count: 12))

        #expect(data.count == 12)
        #expect(data.description == "BookmarkData(12 bytes)")
    }

    @Test func comparesByBytes() {
        #expect(BookmarkData(Data([1])) == BookmarkData(Data([1])))
        #expect(BookmarkData(Data([1])) != BookmarkData(Data([2])))
    }
}
