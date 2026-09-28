import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("FakeBookmarkEngine environments")
struct FakeEnvironmentTests {
    static let environments: [SandboxEnvironment] = [
        .sandboxedMac,
        SandboxEnvironment(platform: .macOS, isSandboxed: false),
        SandboxEnvironment(platform: .macCatalyst, isSandboxed: true),
        SandboxEnvironment(platform: .iOS, isSandboxed: true),
        SandboxEnvironment(platform: .visionOS, isSandboxed: true),
        FakeBookmarkEngine.hostEnvironment,
    ]

    @Test func defaultsToASandboxedAppOnTheHost() {
        let engine = FakeBookmarkEngine()

        #expect(engine.environment == FakeBookmarkEngine.hostEnvironment)
        #expect(engine.environment.platform == SandboxEnvironment.current.platform)
        #expect(engine.environment.isSandboxed)
    }

    /// The picker a real app on the platform hands grants from.
    static func origin(on platform: SandboxEnvironment.Platform) -> Grant.Origin {
        switch platform {
        case .macOS, .macCatalyst: .openPanel
        case .iOS, .visionOS, .other: .documentPicker
        }
    }

    @Test(arguments: environments)
    func adoptingAndLeasingBalancesOnEveryPlatform(_ environment: SandboxEnvironment) async throws {
        let engine = FakeBookmarkEngine(environment: environment)
        engine.addItem(at: "/Users/me/Project")
        let service = BookmarkService(engine: engine, ledger: ScopeLedger())

        let resolved = try await service.adopt(engine.grant("/Users/me/Project", origin: Self.origin(on: environment.platform)))
        let lease = resolved.beginAccess()
        let accessing = engine.isAccessing("/Users/me/Project")
        lease.end()

        #expect(resolved.kind == service.defaultKind)
        #expect(accessing == lease.didStartScope)
        #expect(engine.isBalanced, "\(engine.balanceReport)")
        #expect(engine.startsOnUnissuedURLs.isEmpty)
    }

    @Test(arguments: environments)
    func storesBalanceTheirLeasesOnEveryPlatform(_ environment: SandboxEnvironment) async throws {
        let engine = FakeBookmarkEngine(environment: environment)
        engine.addItem(at: "/Users/me/Project")
        let store = BookmarkStore<String, NoMetadata>(
            persistence: InMemoryPersistence(),
            service: BookmarkService(engine: engine, ledger: ScopeLedger())
        )

        try await store.add(engine.grant("/Users/me/Project", origin: Self.origin(on: environment.platform)), key: "project")
        engine.moveItem(from: "/Users/me/Project", to: "/Users/me/Renamed")
        let path = try await store.withAccess(to: "project") { $0.path(percentEncoded: false) }

        #expect(path == "/Users/me/Renamed/")
        #expect(engine.isBalanced, "\(engine.balanceReport)")
    }

    @Test func aMacEngineTakesScopedOptionsOnAnyHost() throws {
        let engine = FakeBookmarkEngine(environment: .sandboxedMac)
        engine.addItem(at: "/f")
        let grant = engine.grant("/f", origin: .openPanel)

        let data = try engine.makeBookmark(for: grant.url, options: [.scope], includingResourceValuesFor: [], relativeTo: nil)
        let (url, _) = try engine.resolve(data, options: [.scope], relativeTo: nil)

        // A scoped bookmark resolved without the scope option would be taken as implicit and
        // start access; it doesn't.
        _ = try engine.resolve(data, options: [], relativeTo: nil)
        #expect(engine.outstandingAccess == ["/f": 1])
        #expect(url.path(percentEncoded: false) == "/f/")
        withExtendedLifetime(grant) {}
    }

    @Test func iOSEnginesRefuseScopedOptionsOnAnyHost() {
        let engine = FakeBookmarkEngine(environment: SandboxEnvironment(platform: .iOS, isSandboxed: true))
        engine.addItem(at: "/f")
        engine.makeAccessibleWithoutGrant("/f")

        #expect(throws: CocoaError.self) {
            try engine.makeBookmark(for: URL(filePath: "/f"), options: [.scope], includingResourceValuesFor: [], relativeTo: nil)
        }
    }
}

@Suite("FakeBookmarkEngine scripted failures")
struct ScriptedFailureTests {
    let engine = FakeBookmarkEngine(environment: .sandboxedMac)

    func bookmark(_ path: String) throws -> BookmarkData {
        engine.addItem(at: path)
        engine.makeAccessibleWithoutGrant(path)
        return try engine.makeBookmark(for: URL(filePath: path), options: [.scope], includingResourceValuesFor: [], relativeTo: nil)
    }

    func resolves(_ data: BookmarkData) -> Bool {
        (try? engine.resolve(data, options: [.scope], relativeTo: nil)) != nil
    }

    @Test(arguments: [0, -1])
    func noTimesScriptsNoFailure(_ times: Int) throws {
        let data = try bookmark("/f")

        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile, times: times)
        engine.failCreation(of: "/f", with: FakeErrors.denied, times: times)

        #expect(resolves(data))
        _ = try bookmark("/f")
    }

    @Test func zeroTimesClearsAnEarlierScript() throws {
        let data = try bookmark("/f")
        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile)
        engine.failCreation(of: "/f", with: FakeErrors.denied)

        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile, times: 0)
        engine.failCreation(of: "/f", with: FakeErrors.denied, times: 0)

        #expect(resolves(data))
        _ = try bookmark("/f")
    }

    @Test func aCountFailsExactlyThatOften() throws {
        let data = try bookmark("/f")

        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile, times: 1)

        #expect(!resolves(data))
        #expect(resolves(data))
    }

    @Test func aLaterScriptReplacesAnEarlierOne() throws {
        let data = try bookmark("/f")
        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile)

        engine.failResolution(of: "/f", with: FakeErrors.corrupt, times: 1)

        #expect(throws: CocoaError(.fileReadCorruptFile)) { try engine.resolve(data, options: [.scope], relativeTo: nil) }
        #expect(resolves(data))
    }

    @Test func clearingOnePathLeavesTheOthers() throws {
        let f = try bookmark("/f")
        let g = try bookmark("/g")
        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile)
        engine.failResolution(of: "/g", with: FakeErrors.noSuchFile)
        engine.failCreation(of: "/f", with: FakeErrors.denied)
        engine.refuseAccess(to: "/f")

        engine.clearScriptedFailures(of: "/f")

        #expect(resolves(f))
        #expect(!resolves(g))
        _ = try bookmark("/f")
        let (url, _) = try engine.resolve(f, options: [.scope], relativeTo: nil)
        #expect(engine.startAccessing(url))
        engine.stopAccessing(url)
    }

    @Test func clearingEverythingRemovesEveryScript() throws {
        let f = try bookmark("/f")
        let g = try bookmark("/g")
        engine.failResolution(of: "/f", with: FakeErrors.noSuchFile)
        engine.failCreation(of: "/g", with: FakeErrors.denied)
        engine.refuseAccess(to: "/g")
        engine.reportStale("/f")

        engine.clearScriptedFailures()

        #expect(resolves(g))
        _ = try bookmark("/g")
        let (url, isStale) = try engine.resolve(f, options: [.scope], relativeTo: nil)
        #expect(isStale, "forced staleness isn't a failure and stays")
        let (gURL, _) = try engine.resolve(g, options: [.scope], relativeTo: nil)
        #expect(engine.startAccessing(gURL))
        engine.stopAccessing(gURL)
        #expect(url.path(percentEncoded: false) == "/f/")
    }
}
