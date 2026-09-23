@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("Bookmarks: create and adopt")
struct CreateAndAdoptTests {
    let engine = Fixtures.engine()
    var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

    @Suite("Create")
    struct Create {
        let engine = Fixtures.engine()
        var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

        @Test func startsAccessAroundCreationForImporterURLs() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let data = try await bookmarks.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter))

            #expect(data.count > 0)
            #expect(engine.calls.starts == 1)
            #expect(engine.isBalanced)
        }

        @Test func leavesSystemStartedAccessToTheCaller() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            _ = try await bookmarks.create(for: grant)

            #expect(engine.calls.starts == 0)
            #expect(engine.isAccessing("/Users/me/Folder"))
            bookmarks.relinquish(grant)
            #expect(engine.isBalanced)
        }

        static let expectedOptions: [URL.BookmarkCreationOptions] = [
            [.withSecurityScope],
            [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            [],
            [.withoutImplicitSecurityScope],
            [.suitableForBookmarkFile],
        ]

        @Test(arguments: zip(
            [BookmarkKind.appScoped(.readWrite), .appScoped(.readOnly), .implicit, .reference, .alias],
            expectedOptions
        ))
        func passesTheKindsOptions(_ kind: BookmarkKind, _ options: URL.BookmarkCreationOptions) async throws {
            engine.addItem(at: "/Users/me/Folder")

            _ = try await bookmarks.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter), kind: kind)

            #expect(engine.creationRequests.last?.options == options)
        }

        @Test func usesTheEnvironmentsDefaultKind() async throws {
            engine.addItem(at: "/Users/me/Folder")

            _ = try await bookmarks.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter))

            #expect(engine.creationRequests.last?.options == [.withSecurityScope])
        }

        @Test func passesTheDocumentForDocumentScope() async throws {
            engine.addItem(at: "/Users/me/Doc.pages", isDirectory: false)
            engine.addItem(at: "/Users/me/Image.png", isDirectory: false)

            _ = try await bookmarks.create(
                for: engine.grant("/Users/me/Image.png", origin: .fileImporter),
                kind: .documentScoped(.readWrite),
                relativeTo: URL(filePath: "/Users/me/Doc.pages")
            )

            #expect(engine.creationRequests.last?.document == "/Users/me/Doc.pages")
        }

        @Test func alreadyAccessibleGrantsAreNotStarted() async throws {
            engine.addItem(at: "/Container/Data")
            engine.makeAccessibleWithoutGrant("/Container")

            _ = try await bookmarks.create(for: engine.grant("/Container/Data", origin: .alreadyAccessible))

            #expect(engine.calls.starts == 0)
        }

        @Test func failsWithoutAccessInTheSandbox() async {
            engine.addItem(at: "/Users/me/Private")

            await #expect(throws: BookmarkError.self) {
                try await bookmarks.create(for: Grant(url: URL(filePath: "/Users/me/Private"), origin: .alreadyAccessible))
            }
        }

        @Test func reportsMissingItems() async {
            let error = await #expect(throws: BookmarkError.self) {
                try await bookmarks.create(for: engine.grant("/Users/me/Nothing", origin: .fileImporter))
            }

            #expect(error?.failure == .missing)
            #expect(error?.lastKnownPath == "/Users/me/Nothing")
            #expect(engine.isBalanced)
        }

        @Test func classifiesScriptedFailures() async {
            engine.addItem(at: "/Users/me/Folder")
            engine.failCreation(of: "/Users/me/Folder", with: FakeErrors.notPermitted)

            let error = await #expect(throws: BookmarkError.self) {
                try await bookmarks.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter))
            }

            #expect(error?.failure == .denied)
            #expect(engine.isBalanced)
        }

        @Test func rejectsUnsupportedKindsWithoutTouchingTheSystem() async {
            engine.addItem(at: "/Users/me/Folder")

            let error = await #expect(throws: BookmarkError.self) {
                try await bookmarks.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter), kind: .documentScoped(.readWrite))
            }

            guard case .unsupported = error?.failure else {
                Issue.record("Expected unsupported, got \(String(describing: error))")
                return
            }
            #expect(engine.calls.creations == 0)
        }

        @Test func scopedKindsAreUnsupportedOnIOS() async {
            let engine = Fixtures.engine(Fixtures.iOS)
            engine.addItem(at: "/Documents/Folder")

            let error = await #expect(throws: BookmarkError.self) {
                try await Fixtures.bookmarks(engine).create(
                    for: engine.grant("/Documents/Folder", origin: .documentPicker),
                    kind: .appScoped(.readWrite)
                )
            }

            guard case .unsupported = error?.failure else {
                Issue.record("Expected unsupported, got \(String(describing: error))")
                return
            }
        }

        @Test func iOSDefaultsToImplicitBookmarks() async throws {
            let engine = Fixtures.engine(Fixtures.iOS)
            engine.addItem(at: "/Documents/Folder")

            _ = try await Fixtures.bookmarks(engine).create(for: engine.grant("/Documents/Folder", origin: .documentPicker))

            #expect(engine.creationRequests.last?.options == [])
            #expect(engine.isBalanced)
        }
    }

    @Suite("Adopt")
    struct Adopt {
        let engine = Fixtures.engine()
        var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

        @Test(arguments: Grant.Origin.allCases.filter { $0 != .alreadyAccessible && $0 != .implicitBookmark })
        func balancesEveryOrigin(_ origin: Grant.Origin) async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: origin))
            let lease = resolved.beginAccess()

            #expect(lease.isActive)
            lease.end()
            #expect(engine.isBalanced)
        }

        @Test func resolvesTheNewBookmark() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            #expect(resolved.displayPath == "/Users/me/Folder/")
            #expect(!resolved.wasStale)
            #expect(!resolved.needsPersisting)
            #expect(resolved.kind == .appScoped(.readWrite))
            #expect(resolved.recorded?.path == "/Users/me/Folder")
            #expect(engine.calls.resolutions == 1)
        }

        @Test func capturesTheFileIdentityWhileAccessIsHeld() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            #expect(resolved.fileIdentity == engine.fileIdentity(of: URL(filePath: "/Users/me/Folder")))
            #expect(resolved.fileIdentity != nil)
        }

        @Test func leasesUseTheResolvedURLNotTheGrant() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let resolved = try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            let lease = resolved.beginAccess()
            defer { lease.end() }

            #expect(lease.url == resolved.unscopedURL)
            #expect(engine.startsOnUnissuedURLs.isEmpty)
        }

        @Test func relinquishesTheGrantWhenCreationFails() async {
            engine.addItem(at: "/Users/me/Folder")
            engine.failCreation(of: "/Users/me/Folder", with: FakeErrors.denied)

            await #expect(throws: BookmarkError.self) {
                try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: .drop))
            }

            #expect(engine.isBalanced)
        }

        @Test func relinquishesTheGrantWhenTheKindIsUnsupported() async {
            engine.addItem(at: "/Users/me/Folder")

            await #expect(throws: BookmarkError.self) {
                try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: .openPanel), kind: .documentScoped(.readOnly))
            }

            #expect(engine.isBalanced)
        }

        @Test func adoptingOnIOSStartsAroundCreation() async throws {
            let engine = Fixtures.engine(Fixtures.iOS)
            engine.addItem(at: "/Documents/Folder")

            let resolved = try await Fixtures.bookmarks(engine).adopt(engine.grant("/Documents/Folder", origin: .documentPicker))
            let lease = resolved.beginAccess()
            lease.end()

            #expect(resolved.kind == .implicit)
            #expect(engine.calls.starts == 2)
            #expect(engine.isBalanced)
        }

        @Test func relinquishDoesNothingForOriginsTheSystemDidNotStart() {
            engine.addItem(at: "/Users/me/Folder")

            bookmarks.relinquish(engine.grant("/Users/me/Folder", origin: .fileImporter))

            #expect(engine.calls.stops == 0)
        }
    }

    @Suite("Grant origins")
    struct Origins {
        @Test(arguments: [Grant.Origin.openPanel, .savePanel, .drop, .finderOpen])
        func systemStartedOnMacOnly(_ origin: Grant.Origin) {
            let grant = Grant(url: URL(filePath: "/x"), origin: origin)

            #expect(grant.isStartedBySystem(on: .macOS))
            #expect(grant.isStartedBySystem(on: .macCatalyst))
            #expect(!grant.isStartedBySystem(on: .iOS))
            #expect(!grant.isStartedBySystem(on: .visionOS))
        }

        @Test(arguments: [Grant.Origin.fileImporter, .documentPicker, .alreadyAccessible])
        func neverStartedBySystem(_ origin: Grant.Origin) {
            let grant = Grant(url: URL(filePath: "/x"), origin: origin)

            for platform in SandboxEnvironment.Platform.allCases {
                #expect(!grant.isStartedBySystem(on: platform))
            }
        }

        @Test func implicitBookmarkURLsAreAlwaysStarted() {
            let grant = Grant(url: URL(filePath: "/x"), origin: .implicitBookmark)

            for platform in SandboxEnvironment.Platform.allCases {
                #expect(grant.isStartedBySystem(on: platform))
            }
        }
    }
}
