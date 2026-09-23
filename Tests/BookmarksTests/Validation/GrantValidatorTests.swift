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

        @Test(arguments: [
            "/", "/Users", "/Volumes", "/System", "/Library", "/Applications", "/private", "/Users/tester",
            "/usr", "/etc", "/opt", "/tmp", "/Users/Shared", "/Users/someone", "/private/swift-bookmarks-missing", "/System/Volumes",
        ])
        func refusesBroadLocations(_ path: String) {
            #expect(base.refusal(.notTooBroad, base.info(path)) == .tooBroad(path: path))
        }

        @Test(arguments: ["/Users/tester/Developer", "/Volumes/External", "/Volumes/External/Builds", "/opt/work", "/Library/Fonts", "/Applications/App.app"])
        func acceptsSpecificLocations(_ path: String) {
            #expect(base.refusal(.notTooBroad, base.info(path)) == nil)
        }

        @Test(arguments: ["/Volumes/Homes", "/Volumes/Homes/tester"])
        func refusesAHomeOutsideUsersAndItsAncestors(_ path: String) {
            let context = ValidationContext(homeDirectory: URL(filePath: "/Volumes/Homes/tester"))

            #expect(NotTooBroadValidator().refusal(for: base.info(path), at: URL(filePath: path), in: context) == .tooBroad(path: path))
            #expect(NotTooBroadValidator().refusal(for: base.info(path + "/Developer"), at: URL(filePath: path), in: context) == nil)
        }

        @Test(arguments: ["/users/someone", "/SYSTEM/Library", "/Private/var", "/system/volumes/data"])
        func refusesSystemLocationsInAnyCaseWhereCaseIsIgnored(_ path: String) {
            let insensitive = ItemInfo(isDirectory: true, isSymbolicLink: false, canonicalPath: path, namesAreCaseSensitive: false)

            #expect(base.refusal(.notTooBroad, insensitive) == .tooBroad(path: path))
        }

        @Test func systemLocationsKeepTheirCaseWhereCaseMatters() {
            #expect(base.refusal(.notTooBroad, base.info("/users/someone")) == nil)
        }

        @Test(arguments: [
            "/System/Volumes/Data", "/System/Volumes/Data/Users", "/System/Volumes/Data/Users/someone",
            "/System/Volumes/Data/private/var", "/System/Volumes/Data/Library",
        ])
        func refusesTheDataVolumeRootAndItsSystemLocations(_ path: String) {
            #expect(base.refusal(.notTooBroad, base.info(path)) == .tooBroad(path: path))
        }

        @Test func acceptsSpecificLocationsOnTheDataVolume() {
            #expect(base.refusal(.notTooBroad, base.info("/System/Volumes/Data/Users/tester/Developer")) == nil)
            #expect(base.refusal(.notTooBroad, base.info("/System/Volumes/Data/opt/work")) == nil)
        }

        @Test func refusesAdditionalPaths() {
            let validator = NotTooBroadValidator(additionalPaths: ["/Users/tester/Developer"])

            #expect(base.refusal(validator, base.info("/Users/tester/Developer")) == .tooBroad(path: "/Users/tester/Developer"))
        }

        @Test func matchesAdditionalPathsWithTrailingSlashes() {
            let validator = NotTooBroadValidator(additionalPaths: ["/Users/tester/Developer/"])

            #expect(base.refusal(validator, base.info("/Users/tester/Developer")) == .tooBroad(path: "/Users/tester/Developer"))
        }

        @Test func matchesAdditionalPathsThroughSymbolicLinks() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "swift-bookmarks-validator-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let real = root.appending(path: "Real")
            let link = root.appending(path: "Link")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let canonical = NormalizedPath(real.resolvingSymlinksInPath()).string
            let validator = NotTooBroadValidator(additionalPaths: [link.path(percentEncoded: false)])

            #expect(base.refusal(validator, base.info(canonical)) == .tooBroad(path: canonical))
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

        @Test func ignoresCaseOnlyWhereTheVolumeDoes() {
            let insensitive = ItemInfo(isDirectory: true, isSymbolicLink: false, canonicalPath: "/users/tester/projects", namesAreCaseSensitive: false)
            let sensitive = ItemInfo(isDirectory: true, isSymbolicLink: false, canonicalPath: "/users/tester/projects")

            #expect(base.refusal(.noOverlap, insensitive, existing: existing) == .duplicate(path: "/users/tester/projects"))
            #expect(base.refusal(.noOverlap, sensitive, existing: existing) == nil)
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
