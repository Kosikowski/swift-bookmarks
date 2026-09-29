@testable import Bookmarks
import BookmarksTesting
import Foundation
import Synchronization
import Testing

@Suite("BookmarkService: create and adopt")
struct CreateAndAdoptTests {
    let engine = Fixtures.engine()
    var service: BookmarkService { Fixtures.service(engine) }

    @Suite("Create")
    struct Create {
        let engine = Fixtures.engine()
        var service: BookmarkService { Fixtures.service(engine) }

        @Test func startsAccessAroundCreationForImporterURLs() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let data = try await service.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter))

            #expect(data.count > 0)
            #expect(engine.calls.starts == 1)
            #expect(engine.isBalanced)
        }

        @Test func leavesSystemStartedAccessToTheCaller() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            _ = try await service.create(for: grant)

            #expect(engine.calls.starts == 0)
            #expect(engine.isAccessing("/Users/me/Folder"))
            service.relinquish(grant)
            #expect(engine.isBalanced)
        }

        static let expectedOptions: [URL.BookmarkCreationOptions] = [
            [.securityScope],
            [.securityScope, .securityScopeReadOnly],
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

            _ = try await service.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter), kind: kind)

            #expect(engine.creationRequests.last?.options == options)
        }

        @Test func usesTheEnvironmentsDefaultKind() async throws {
            engine.addItem(at: "/Users/me/Folder")

            _ = try await service.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter))

            #expect(engine.creationRequests.last?.options == [.securityScope])
        }

        @Test func alreadyAccessibleGrantsAreNotStarted() async throws {
            engine.addItem(at: "/Container/Data")
            engine.makeAccessibleWithoutGrant("/Container")

            _ = try await service.create(for: engine.grant("/Container/Data", origin: .alreadyAccessible))

            #expect(engine.calls.starts == 0)
        }

        @Test func failsWithoutAccessInTheSandbox() async {
            engine.addItem(at: "/Users/me/Private")

            await #expect(throws: BookmarkError.self) {
                try await service.create(for: Grant(url: URL(filePath: "/Users/me/Private"), origin: .alreadyAccessible))
            }
        }

        @Test func reportsMissingItems() async {
            let error = await #expect(throws: BookmarkError.self) {
                try await service.create(for: engine.grant("/Users/me/Nothing", origin: .fileImporter))
            }

            #expect(error?.failure == .missing)
            #expect(error?.lastKnownPath == "/Users/me/Nothing")
            #expect(engine.isBalanced)
        }

        @Test func classifiesScriptedFailures() async {
            engine.addItem(at: "/Users/me/Folder")
            engine.failCreation(of: "/Users/me/Folder", with: FakeErrors.notPermitted)

            let error = await #expect(throws: BookmarkError.self) {
                try await service.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter))
            }

            #expect(error?.failure == .denied)
            #expect(engine.isBalanced)
        }

        @Test func rejectsUnsupportedKindsWithoutTouchingTheSystem() async {
            engine.addItem(at: "/Users/me/Folder")

            let error = await #expect(throws: BookmarkError.self) {
                try await service.create(for: engine.grant("/Users/me/Folder", origin: .fileImporter), kind: .documentScoped(.readWrite))
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
                try await Fixtures.service(engine).create(
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

            _ = try await Fixtures.service(engine).create(for: engine.grant("/Documents/Folder", origin: .documentPicker))

            #expect(engine.creationRequests.last?.options == [])
            #expect(engine.isBalanced)
        }
    }

    @Suite("Adopt")
    struct Adopt {
        let engine = Fixtures.engine()
        var service: BookmarkService { Fixtures.service(engine) }

        @Test(arguments: Grant.Origin.allCases.filter { $0 != .alreadyAccessible && $0 != .implicitBookmark })
        func balancesEveryOrigin(_ origin: Grant.Origin) async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await service.adopt(engine.grant("/Users/me/Folder", origin: origin))
            let lease = resolved.beginAccess()

            #expect(lease.isActive)
            lease.end()
            #expect(engine.isBalanced)
        }

        @Test func resolvesTheNewBookmark() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await service.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            #expect(resolved.displayPath == "/Users/me/Folder/")
            #expect(!resolved.wasStale)
            #expect(!resolved.needsPersisting)
            #expect(resolved.kind == .appScoped(.readWrite))
            #expect(resolved.recorded?.path == "/Users/me/Folder")
            #expect(engine.calls.resolutions == 1)
        }

        @Test func capturesTheFileIdentityWhileAccessIsHeld() async throws {
            engine.addItem(at: "/Users/me/Folder")

            let resolved = try await service.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            #expect(resolved.fileIdentity == engine.fileIdentity(of: URL(filePath: "/Users/me/Folder")))
            #expect(resolved.fileIdentity != nil)
        }

        @Test func leasesUseTheResolvedURLNotTheGrant() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let resolved = try await service.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            let lease = resolved.beginAccess()
            defer { lease.end() }

            #expect(lease.url == resolved.url)
            #expect(engine.startsOnUnissuedURLs.isEmpty)
        }

        @Test func relinquishesTheGrantWhenCreationFails() async {
            engine.addItem(at: "/Users/me/Folder")
            engine.failCreation(of: "/Users/me/Folder", with: FakeErrors.denied)

            await #expect(throws: BookmarkError.self) {
                try await service.adopt(engine.grant("/Users/me/Folder", origin: .appKitDrop))
            }

            #expect(engine.isBalanced)
        }

        @Test func relinquishesTheGrantWhenTheKindIsUnsupported() async {
            engine.addItem(at: "/Users/me/Folder")

            await #expect(throws: BookmarkError.self) {
                try await service.adopt(engine.grant("/Users/me/Folder", origin: .openPanel), kind: .documentScoped(.readOnly))
            }

            #expect(engine.isBalanced)
        }

        @Test func adoptingOnIOSStartsAroundCreation() async throws {
            let engine = Fixtures.engine(Fixtures.iOS)
            engine.addItem(at: "/Documents/Folder")

            let resolved = try await Fixtures.service(engine).adopt(engine.grant("/Documents/Folder", origin: .documentPicker))
            let lease = resolved.beginAccess()
            lease.end()

            #expect(resolved.kind == .implicit)
            #expect(engine.calls.starts == 2)
            #expect(engine.isBalanced)
        }

        @Test func bookmarksStaleOnArrivalKeepTheirRefresh() async throws {
            engine.addItem(at: "/Users/me/Folder")
            engine.reportStale("/Users/me/Folder")

            let resolved = try await service.adopt(engine.grant("/Users/me/Folder", origin: .openPanel))

            #expect(resolved.wasStale)
            let refreshed = try #require(resolved.refreshedData)
            #expect(resolved.data == refreshed)
            #expect(resolved.needsPersisting)
            #expect(try await !service.resolve(refreshed).wasStale)
            #expect(engine.isBalanced)
        }

        @Test(.timeLimit(.minutes(1)))
        func aTimedOutAdoptionKeepsTheGrantUntilCreationEnds() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let service = Fixtures.service(engine, timeout: .milliseconds(30))
            let gate = engine.holdCreation(of: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            let error = await #expect(throws: BookmarkError.self) { try await service.adopt(grant) }

            #expect(error?.failure == .timedOut)
            #expect(engine.isAccessing("/Users/me/Folder"))
            #expect(!grant.isConsumed)
            gate.open()
            while !grant.isConsumed {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(engine.isBalanced)
        }

        @Test func relinquishDoesNothingForOriginsTheSystemDidNotStart() {
            engine.addItem(at: "/Users/me/Folder")

            service.relinquish(engine.grant("/Users/me/Folder", origin: .fileImporter))

            #expect(engine.calls.stops == 0)
        }
    }

    @Suite("Grant use")
    struct GrantUse {
        let engine = Fixtures.engine()
        var service: BookmarkService { Fixtures.service(engine) }

        @Test func relinquishingTwiceStopsOnce() {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            service.relinquish(grant)
            service.relinquish(grant)

            #expect(grant.isConsumed)
            #expect(engine.calls.stops == 1)
            #expect(engine.isBalanced)
        }

        @Test func adoptedGrantsAreNotRelinquishedAgain() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            let resolved = try await service.adopt(grant)
            service.relinquish(grant)
            resolved.beginAccess().end()

            #expect(engine.isBalanced)
        }

        @Test func aUsedGrantCantBeAdoptedAgain() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)
            service.relinquish(grant)

            let error = await #expect(throws: BookmarkError.self) { try await service.adopt(grant) }

            guard case .unsupported = error?.failure else {
                Issue.record("Expected unsupported, got \(String(describing: error))")
                return
            }
            #expect(engine.isBalanced)
        }

        @Test(.timeLimit(.minutes(1)))
        func oneGrantBacksOneCreationAtATime() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)
            let gate = engine.holdCreation(of: "/Users/me/Folder")
            let service = service

            let first = Task { try await service.adopt(grant) }
            await gate.waitUntilReached()
            let error = await #expect(throws: BookmarkError.self) { try await service.adopt(grant) }
            gate.open()
            let resolved = try await first.value

            guard case .unsupported = error?.failure else {
                Issue.record("Expected unsupported, got \(String(describing: error))")
                return
            }
            #expect(engine.calls.creations == 1)
            resolved.beginAccess().end()
            #expect(engine.isBalanced)
        }

        @Test(.timeLimit(.minutes(1)))
        func relinquishingDuringCreationWaitsForItToEnd() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)
            let gate = engine.holdCreation(of: "/Users/me/Folder")
            let service = service

            let adoption = Task { try await service.adopt(grant) }
            await gate.waitUntilReached()
            service.relinquish(grant)

            #expect(engine.isAccessing("/Users/me/Folder"))
            #expect(!grant.isConsumed)
            gate.open()
            _ = try await adoption.value
            #expect(grant.isConsumed)
            #expect(engine.calls.stops == 1)
            #expect(engine.isBalanced)
        }

        @Test func aGrantStaysUsableAfterCreatingFromIt() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)

            _ = try await service.create(for: grant)
            #expect(!grant.isConsumed)
            #expect(engine.isAccessing("/Users/me/Folder"))
            _ = try await service.adopt(grant)

            #expect(grant.isConsumed)
            #expect(engine.isBalanced)
        }

        @Test(.timeLimit(.minutes(1)))
        func relinquishingDuringCreateUsesUpTheGrantOnceCreationEnds() async throws {
            engine.addItem(at: "/Users/me/Folder")
            let grant = engine.grant("/Users/me/Folder", origin: .openPanel)
            let gate = engine.holdCreation(of: "/Users/me/Folder")
            let service = service

            let creation = Task { try await service.create(for: grant) }
            await gate.waitUntilReached()
            service.relinquish(grant)
            gate.open()
            _ = try await creation.value

            #expect(grant.isConsumed)
            #expect(engine.isBalanced)
        }

        @Test func droppedGrantsBalanceTheSystemStart() {
            engine.addItem(at: "/Users/me/Folder")

            do {
                let grant = engine.grant("/Users/me/Folder", origin: .openPanel)
                #expect(engine.isAccessing("/Users/me/Folder"))
                _ = grant
            }

            #expect(engine.isBalanced)
        }

        @Test func droppedGrantsTheSystemDidntStartStopNothing() {
            engine.addItem(at: "/Users/me/Folder")

            do {
                _ = engine.grant("/Users/me/Folder", origin: .fileImporter)
            }

            #expect(engine.calls.stops == 0)
        }
    }

    @Suite("Grant origins")
    struct Origins {
        @Test(arguments: [Grant.Origin.openPanel, .savePanel, .appKitDrop, .finderOpen])
        func systemStartedOnMacOnly(_ origin: Grant.Origin) {
            #expect(origin.isStartedBySystem(on: .macOS))
            #expect(origin.isStartedBySystem(on: .macCatalyst))
            #expect(!origin.isStartedBySystem(on: .iOS))
            #expect(!origin.isStartedBySystem(on: .visionOS))
        }

        /// Observed in the integration host: a dropped folder is readable before any start,
        /// and one stop ends access. Without that stop, every drop leaked a scope.
        @Test func swiftUIDropsAreStartedOnMacOS() {
            #expect(Grant.Origin.swiftUIDrop.isStartedBySystem(on: .macOS))
            #expect(!Grant.Origin.swiftUIDrop.isStartedBySystem(on: .macCatalyst))
            #expect(!Grant.Origin.swiftUIDrop.isStartedBySystem(on: .iOS))
            #expect(!Grant.Origin.swiftUIDrop.isStartedBySystem(on: .visionOS))
        }

        @Test(arguments: [Grant.Origin.fileImporter, .documentPicker, .alreadyAccessible])
        func neverStartedBySystem(_ origin: Grant.Origin) {
            for platform in SandboxEnvironment.Platform.allCases {
                #expect(!origin.isStartedBySystem(on: platform))
            }
        }

        @Test func implicitBookmarkURLsAreAlwaysStarted() {
            for platform in SandboxEnvironment.Platform.allCases {
                #expect(Grant.Origin.implicitBookmark.isStartedBySystem(on: platform))
            }
        }

        @Test func aGrantRecordsWhetherItsPlatformStartedAccess() {
            let mac = Grant(url: URL(filePath: "/x"), origin: .openPanel, platform: .macOS) { _ in }
            let iPhone = Grant(url: URL(filePath: "/x"), origin: .openPanel, platform: .iOS) { _ in }

            #expect(mac.isStartedBySystem)
            #expect(!iPhone.isStartedBySystem)
        }

        @Test func relinquishingAndReleasingStopThroughTheGrantOnce() {
            let stops = Mutex(0)
            let grant = Grant(url: URL(filePath: "/x"), origin: .openPanel, platform: .macOS) { _ in
                stops.withLock { $0 += 1 }
            }
            let service = Fixtures.service(Fixtures.engine())

            service.relinquish(grant)
            service.relinquish(grant)
            #expect(grant.isConsumed)
            #expect(stops.withLock { $0 } == 1)
        }

        @Test func releasingAnUnusedGrantStopsThroughTheGrant() {
            let stops = Mutex(0)
            do {
                _ = Grant(url: URL(filePath: "/x"), origin: .finderOpen, platform: .macCatalyst) { _ in
                    stops.withLock { $0 += 1 }
                }
            }
            #expect(stops.withLock { $0 } == 1)
        }
    }
}
