@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkService: one-shot access to grants")
struct GrantAccessTests {
    let engine = Fixtures.engine()
    var service: BookmarkService { Fixtures.service(engine) }

    func grant(_ origin: Grant.Origin, path: String = "/Users/me/Folder") -> Grant {
        engine.addItem(at: path)
        return engine.grant(path, origin: origin)
    }

    @Test(arguments: [Grant.Origin.openPanel, .savePanel, .appKitDrop, .swiftUIDrop, .finderOpen, .implicitBookmark])
    func takesOverTheSystemsStart(_ origin: Grant.Origin) throws {
        let grant = grant(origin)

        let lease = try service.beginAccess(to: grant)

        #expect(lease.didStartScope)
        #expect(lease.isActive)
        #expect(engine.calls.starts == 0, "the system's start is reused, not repeated")
        #expect(engine.outstandingAccess == ["/Users/me/Folder": 1])
        #expect(grant.isConsumed)
        lease.end()
        #expect(engine.isBalanced, "\(engine.balanceReport)")
        #expect(engine.calls.creations == 0)
    }

    @Test(arguments: [Grant.Origin.fileImporter, .documentPicker])
    func startsAccessForOriginsTheSystemDoesntStart(_ origin: Grant.Origin) throws {
        let grant = grant(origin)

        let lease = try service.beginAccess(to: grant)

        #expect(lease.didStartScope)
        #expect(engine.calls.starts == 1)
        #expect(engine.isAccessing("/Users/me/Folder"))
        lease.end()
        #expect(!engine.isAccessing("/Users/me/Folder"))
        #expect(engine.isBalanced, "\(engine.balanceReport)")
        #expect(engine.calls.creations == 0)
    }

    @Test func startsNothingForLocationsTheAppAlreadyReaches() throws {
        let grant = grant(.alreadyAccessible)

        let lease = try service.beginAccess(to: grant)
        lease.end()

        #expect(!lease.didStartScope)
        #expect(engine.calls.starts == 0)
        #expect(engine.calls.stops == 0)
    }

    @Test func theLeaseUsesTheGrantedURL() throws {
        let grant = grant(.fileImporter)

        let lease = try service.beginAccess(to: grant)
        defer { lease.end() }

        #expect(lease.url == grant.url)
        #expect(lease.url(forDescendant: URL(filePath: "/Users/me/Folder/Project/file.json"))?.path(percentEncoded: false) == "/Users/me/Folder/Project/file.json")
        #expect(engine.startsOnUnissuedURLs.isEmpty)
    }

    @Test func aGrantIsUsedOnce() async throws {
        let grant = grant(.openPanel)
        let lease = try service.beginAccess(to: grant)
        defer { lease.end() }

        let again = #expect(throws: BookmarkError.self) { try service.beginAccess(to: grant) }
        let adopted = await #expect(throws: BookmarkError.self) { try await service.adopt(grant) }

        guard case .unsupported = again?.failure, case .unsupported = adopted?.failure else {
            Issue.record("Expected unsupported, got \(String(describing: again)) and \(String(describing: adopted))")
            return
        }
        service.relinquish(grant)
        #expect(engine.outstandingAccess == ["/Users/me/Folder": 1], "relinquishing a used grant stops nothing")
    }

    @Test func relinquishedGrantsCantBeUsed() {
        let grant = grant(.openPanel)
        service.relinquish(grant)

        #expect(throws: BookmarkError.self) { try service.beginAccess(to: grant) }
        #expect(engine.isBalanced)
    }

    @Test func aGrantBeingAdoptedCantBeUsed() async throws {
        let grant = grant(.openPanel)
        let gate = engine.holdCreation(of: "/Users/me/Folder")
        let service = service

        let adoption = Task { try await service.adopt(grant) }
        await gate.waitUntilReached()
        let error = #expect(throws: BookmarkError.self) { try service.beginAccess(to: grant) }
        gate.open()
        _ = try await adoption.value

        guard case .unsupported = error?.failure else {
            Issue.record("Expected unsupported, got \(String(describing: error))")
            return
        }
        #expect(engine.isBalanced, "\(engine.balanceReport)")
    }

    @Test func aDroppedLeaseEndsItself() throws {
        do {
            _ = try service.beginAccess(to: grant(.openPanel))
        }

        #expect(engine.isBalanced, "\(engine.balanceReport)")
    }

    @Test func coveringLeasesJoinTheGrantsAccess() throws {
        let service = service
        let lease = try service.beginAccess(to: grant(.fileImporter))

        let inner = try #require(service.ledger.lease(covering: URL(filePath: "/Users/me/Folder/inner.json")))
        lease.end()

        #expect(inner.isActive)
        #expect(engine.calls.starts == 1)
        inner.end()
        #expect(engine.isBalanced, "\(engine.balanceReport)")
    }

    @Suite("withAccess")
    struct WithAccess {
        let engine = Fixtures.engine()
        var service: BookmarkService { Fixtures.service(engine) }

        struct WriteFailed: Error {}

        @Test func runsTheBodyWithAccessAndEndsIt() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .fileImporter)
            let engine = engine

            let path = try await service.withAccess(to: grant) { folder in
                #expect(engine.isAccessing("/Users/me/Folder"))
                return folder.path(percentEncoded: false)
            }

            #expect(path == "/Users/me/Folder/")
            #expect(engine.isBalanced, "\(engine.balanceReport)")
            #expect(engine.calls.creations == 0)
        }

        @Test func endsAccessWhenTheBodyThrows() async {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            await #expect(throws: WriteFailed.self) {
                try await service.withAccess(to: grant) { _ in throw WriteFailed() }
            }

            #expect(grant.isConsumed)
            #expect(engine.isBalanced, "\(engine.balanceReport)")
        }

        @Test func failsForAUsedGrant() async {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .fileImporter)
            service.relinquish(grant)

            await #expect(throws: BookmarkError.self) {
                try await service.withAccess(to: grant) { _ in Issue.record("The body ran") }
            }
        }
    }

    @Suite("Other platforms")
    struct OtherPlatforms {
        @Test(arguments: [
            (SandboxEnvironment(platform: .iOS, isSandboxed: true), Grant.Origin.documentPicker, 1),
            (SandboxEnvironment(platform: .visionOS, isSandboxed: true), .fileImporter, 1),
            (SandboxEnvironment(platform: .macCatalyst, isSandboxed: true), .swiftUIDrop, 1),
            (SandboxEnvironment(platform: .macCatalyst, isSandboxed: true), .openPanel, 0),
        ])
        func balancesEveryOriginAsThePlatformHandsItOver(_ environment: SandboxEnvironment, _ origin: Grant.Origin, _ starts: Int) async throws {
            let engine = FakeBookmarkEngine(environment: environment)
            engine.addItem(at: "/Users/me/Folder")
            let service = Fixtures.service(engine)

            try await service.withAccess(to: engine.grant("/Users/me/Folder", origin: origin)) { _ in
                #expect(engine.isAccessing("/Users/me/Folder"))
            }

            #expect(engine.calls.starts == starts)
            #expect(engine.isBalanced, "\(engine.balanceReport)")
        }
    }
}
