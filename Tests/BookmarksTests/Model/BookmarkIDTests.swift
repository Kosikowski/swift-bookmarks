import Bookmarks
import Foundation
import Testing

@Suite("BookmarkID")
struct BookmarkIDTests {
    @Test func newIdentifiersAreUnique() {
        let ids = Set((0..<100).map { _ in BookmarkID() })

        #expect(ids.count == 100)
    }

    @Test func parsesValidUUIDStrings() throws {
        let uuid = UUID()

        let id = try #require(BookmarkID(uuidString: uuid.uuidString))

        #expect(id.rawValue == uuid)
        #expect(id.description == uuid.uuidString)
    }

    @Test(arguments: ["", "not-a-uuid", "12345678-1234-1234-1234"])
    func rejectsMalformedStrings(_ string: String) {
        #expect(BookmarkID(uuidString: string) == nil)
    }

    @Test func encodesAsAPlainUUIDString() throws {
        let uuid = try #require(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        let json = try JSONEncoder().encode(BookmarkID(uuid))

        #expect(String(decoding: json, as: UTF8.self) == "\"E621E1F8-C36C-495A-93FC-0C247A3E6E5F\"")
        #expect(try JSONDecoder().decode(BookmarkID.self, from: json) == BookmarkID(uuid))
    }

    @Test func worksAsADictionaryKeyInJSON() throws {
        let id = BookmarkID()
        let encoded = try JSONEncoder().encode([id: "value"])

        let decoded = try JSONDecoder().decode([BookmarkID: String].self, from: encoded)

        #expect(decoded == [id: "value"])
    }
}
