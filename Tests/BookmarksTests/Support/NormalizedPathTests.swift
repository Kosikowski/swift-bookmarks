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

    @Test func composedAndDecomposedNamesMatch() {
        let composed = NormalizedPath("/Users/me/Caf\u{E9}")
        let decomposed = NormalizedPath("/Users/me/Cafe\u{301}/Menu")

        #expect(composed.contains(decomposed))
        #expect(composed.relativeComponents(of: decomposed) == ["Menu"])
    }

    @Test func privateFirmlinksMatchTheirShortSpelling() {
        let short = NormalizedPath("/var/folders/x")
        let long = NormalizedPath("/private/var/folders/x/file")

        #expect(short.contains(long))
        #expect(short.relativeComponents(of: long) == ["file"])
        #expect(NormalizedPath("/private/var/folders/x").contains(NormalizedPath("/var/folders/x/file")))
        #expect(NormalizedPath("/private/other") != NormalizedPath("/other"))
    }

    @Test func caseMattersOnlyOnCaseSensitiveVolumes() {
        let insensitive = NormalizedPath("/Users/me/Projects", isCaseSensitive: false)
        let sensitive = NormalizedPath("/Users/me/Projects")
        let query = NormalizedPath("/users/ME/projects/App")

        #expect(insensitive.contains(query))
        #expect(insensitive.relativeComponents(of: query) == ["App"])
        #expect(!sensitive.contains(query))
        #expect(insensitive.matches(NormalizedPath("/USERS/me/projects")))
    }
}
