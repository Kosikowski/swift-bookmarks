@testable import Bookmarks
import Foundation
import Testing

@Suite("NormalizedPath")
struct NormalizedPathTests {
    @Test(arguments: [
        ("/Users/me/", "/Users/me"),
        ("/Users/me/./Projects/../Notes", "/Users/me/Notes"),
        ("/", "/"),
        ("//Users//me", "/Users/me"),
    ])
    func normalisesSpellings(_ path: String, _ expected: String) {
        #expect(NormalizedPath(path).string == expected)
        #expect(NormalizedPath(path).description == expected)
        #expect(NormalizedPath(URL(filePath: path)) == NormalizedPath(expected))
    }

    @Test func containsItselfAndDescendantsOnly() {
        let root = NormalizedPath("/Users/me/Projects")

        #expect(root.contains(root))
        #expect(root.contains(NormalizedPath("/Users/me/Projects/App")))
        #expect(!root.contains(NormalizedPath("/Users/me/ProjectsArchive")))
        #expect(!root.contains(NormalizedPath("/Users/me")))
        #expect(NormalizedPath("/").contains(root))
    }

    @Test func relativeComponentsOfDescendants() {
        let root = NormalizedPath("/Users/me")

        #expect(root.relativeComponents(of: NormalizedPath("/Users/me/a/b")) == ["a", "b"])
        #expect(root.relativeComponents(of: root) == [])
        #expect(root.relativeComponents(of: NormalizedPath("/Users/other")) == nil)
    }
}
