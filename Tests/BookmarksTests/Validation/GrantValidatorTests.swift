@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("Grant validators")
struct GrantValidatorTests {
    let home = URL(filePath: "/Users/tester")

    func info(_ path: String, directory: Bool = true, link: Bool = false) -> ItemInfo {
        ItemInfo(isDirectory: directory, isSymbolicLink: link, canonicalPath: path)
    }

    func context(_ existing: [String] = []) -> ValidationContext {
        ValidationContext(existingPaths: existing, homeDirectory: home)
    }

    func refusal(_ validator: some GrantValidator, _ item: ItemInfo, existing: [String] = []) -> GrantRefusal? {
        validator.refusal(for: item, at: URL(filePath: item.canonicalPath), in: context(existing))
    }

    @Suite("Not too broad")
    struct NotTooBroad {
        let base = GrantValidatorTests()

        @Test(arguments: ["/", "/Users", "/Volumes", "/System", "/Library", "/Applications", "/private", "/Users/tester"])
        func refusesBroadLocations(_ path: String) {
            #expect(base.refusal(.notTooBroad, base.info(path)) == .tooBroad(path: path))
        }

        @Test(arguments: ["/Users/tester/Developer", "/Volumes/External", "/Volumes/External/Builds", "/opt/work"])
        func acceptsSpecificLocations(_ path: String) {
            #expect(base.refusal(.notTooBroad, base.info(path)) == nil)
        }

        @Test func refusesAdditionalPaths() {
            let validator = NotTooBroadValidator(additionalPaths: ["/Users/tester/Developer"])

            #expect(base.refusal(validator, base.info("/Users/tester/Developer")) == .tooBroad(path: "/Users/tester/Developer"))
        }
    }

    @Test func directoryOnly() {
        #expect(refusal(.directoryOnly, info("/a")) == nil)
        #expect(refusal(.directoryOnly, info("/a.txt", directory: false)) == .notDirectory(path: "/a.txt"))
    }

    @Test func fileOnly() {
        #expect(refusal(.fileOnly, info("/a.txt", directory: false)) == nil)
        #expect(refusal(.fileOnly, info("/a")) == .notFile(path: "/a"))
    }

    @Test func noSymbolicLink() {
        #expect(refusal(.noSymbolicLink, info("/a")) == nil)
        #expect(refusal(.noSymbolicLink, info("/a", link: true)) == .symbolicLink(path: "/a"))
    }

    @Suite("Overlap")
    struct Overlap {
        let base = GrantValidatorTests()
        let existing = ["/Users/tester/Projects", "/Users/tester/Other/"]

        @Test func refusesDuplicates() {
            #expect(base.refusal(.noOverlap, base.info("/Users/tester/Other"), existing: existing) == .duplicate(path: "/Users/tester/Other"))
        }

        @Test func refusesChildren() {
            let refusal = base.refusal(.noOverlap, base.info("/Users/tester/Projects/App"), existing: existing)

            #expect(refusal == .insideExisting(existing: "/Users/tester/Projects"))
        }

        @Test func refusesParents() {
            let refusal = base.refusal(.noOverlap, base.info("/Users/tester"), existing: existing)

            #expect(refusal == .containsExisting(existing: "/Users/tester/Projects"))
        }

        @Test func acceptsSiblingsWithSharedPrefixes() {
            #expect(base.refusal(.noOverlap, base.info("/Users/tester/ProjectsArchive"), existing: existing) == nil)
        }

        @Test func noDuplicateAllowsNesting() {
            #expect(base.refusal(.noDuplicate, base.info("/Users/tester/Projects/App"), existing: existing) == nil)
            #expect(base.refusal(.noDuplicate, base.info("/Users/tester/Projects"), existing: existing) == .duplicate(path: "/Users/tester/Projects"))
        }
    }

    @Test func coversTarget() {
        let validator = CoversValidator.covers(URL(filePath: "/Users/tester/Library/Developer/Xcode/DerivedData"))

        #expect(refusal(validator, info("/Users/tester/Library/Developer")) == nil)
        #expect(refusal(validator, info("/Users/tester/Library/Developer/Xcode/DerivedData")) == nil)
        #expect(refusal(validator, info("/Users/tester/Documents")) == .doesNotCover(target: "/Users/tester/Library/Developer/Xcode/DerivedData"))
    }

    @Test func customValidatorsSeeEverything() {
        let validator = CustomValidator { item, url, context in
            item.canonicalPath.hasSuffix(".git") || context.existingPaths.count > 1 || url.lastPathComponent.isEmpty
                ? .custom("Nope")
                : nil
        }

        #expect(refusal(validator, info("/repo.git")) == .custom("Nope"))
        #expect(refusal(validator, info("/repo")) == nil)
        #expect(refusal(validator, info("/repo"), existing: ["/a", "/b"]) == .custom("Nope"))
    }

    @Test func everyRefusalHasAMessage() {
        let refusals: [GrantRefusal] = [
            .tooBroad(path: "/"), .notDirectory(path: "/f"), .notFile(path: "/d"), .symbolicLink(path: "/l"),
            .duplicate(path: "/a"), .insideExisting(existing: "/a"), .containsExisting(existing: "/a"),
            .doesNotCover(target: "/t"), .uninspectable(path: "/u"), .custom("Custom reason"),
        ]

        for refusal in refusals {
            #expect(!refusal.message.isEmpty)
            #expect(BookmarkError(.refused(refusal)).errorDescription == refusal.message)
        }
        #expect(GrantRefusal.custom("Custom reason").message == "Custom reason")
    }

    @Test func defaultContextUsesTheRealHome() {
        #expect(ValidationContext().homeDirectory == SandboxEnvironment.realHomeDirectory)
        #expect(ValidationContext().existingPaths.isEmpty)
    }

    @Suite("During adoption")
    struct DuringAdoption {
        let engine = Fixtures.engine()
        var service: BookmarkService { Fixtures.service(engine) }

        @Test func runWhileAccessIsHeldAndRefuseBeforeCreating() async {
            engine.addItem(at: "/Users/me/file.txt", isDirectory: false)

            let error = await #expect(throws: BookmarkError.self) {
                try await service.adopt(engine.grant("/Users/me/file.txt", origin: .fileImporter), validators: [.directoryOnly])
            }

            #expect(error?.failure == .refused(.notDirectory(path: "/Users/me/file.txt")))
            #expect(error?.failure.recommendation == .regrant)
            #expect(engine.calls.creations == 0)
            #expect(engine.calls.starts == 1)
            #expect(engine.isBalanced)
        }

        @Test func seeCanonicalPathsThroughSymbolicLinks() async {
            engine.addItem(at: "/Users/me/Real")
            engine.addSymbolicLink(at: "/Users/me/Link", pointingTo: "/Users/me/Real")

            let error = await #expect(throws: BookmarkError.self) {
                try await service.adopt(
                    engine.grant("/Users/me/Link", origin: .openPanel),
                    validators: [.noOverlap],
                    context: ValidationContext(existingPaths: ["/Users/me/Real"])
                )
            }

            #expect(error?.failure == .refused(.duplicate(path: "/Users/me/Real")))
            #expect(engine.isBalanced)
        }

        @Test func refuseSymbolicLinks() async {
            engine.addItem(at: "/Users/me/Real")
            engine.addSymbolicLink(at: "/Users/me/Link", pointingTo: "/Users/me/Real")

            let error = await #expect(throws: BookmarkError.self) {
                try await service.adopt(engine.grant("/Users/me/Link", origin: .appKitDrop), validators: [.noSymbolicLink])
            }

            #expect(error?.failure == .refused(.symbolicLink(path: "/Users/me/Link")))
        }

        @Test func uninspectableItemsAreRefused() async {
            let error = await #expect(throws: BookmarkError.self) {
                try await service.adopt(engine.grant("/Users/me/Missing", origin: .openPanel), validators: [.directoryOnly])
            }

            #expect(error?.failure == .refused(.uninspectable(path: "/Users/me/Missing")))
            #expect(engine.isBalanced)
        }

        @Test func acceptedItemsAreAdopted() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await service.adopt(engine.grant("/Users/me/Folder", origin: .openPanel), validators: [.directoryOnly, .noSymbolicLink])

            #expect(resolved.displayPath == "/Users/me/Folder/")
        }
    }
}
