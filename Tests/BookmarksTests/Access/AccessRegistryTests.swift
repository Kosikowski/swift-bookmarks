@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("AccessRegistry")
struct AccessRegistryTests {
    let engine = Fixtures.engine()
    let registry: AccessRegistry<String>

    init() {
        registry = AccessRegistry(engine: engine)
    }

    func issue(_ path: String) -> URL {
        engine.addItem(at: path)
        return engine.grant(path, origin: .fileImporter).url
    }

    func lease(_ key: String, _ url: URL, alreadyStarted: Bool = false) -> AccessLease {
        registry.lease(for: key, url: url) { alreadyStarted }
    }

    @Test func startsOncePerKey() {
        let url = issue("/A")

        let first = lease("a", url)
        let second = lease("a", url)

        #expect(engine.calls.starts == 1)
        #expect(first.isActive && second.isActive)
        first.end()
        second.end()
        #expect(engine.isBalanced)
    }

    @Test func reusesActiveAccessInsteadOfANewURL() {
        let original = issue("/A")
        let other = issue("/A-copy")

        let first = lease("a", original)
        let second = lease("a", other)

        #expect(second.url == original)
        #expect(engine.calls.starts == 1)
        first.end()
        second.end()
        #expect(engine.isBalanced)
    }

    @Test func leavesAnUnusedStartWithItsResolvedBookmarkWhenTheKeyIsActive() async throws {
        let engine = Fixtures.engine(Fixtures.iOS)
        let registry = AccessRegistry<String>(engine: engine)
        engine.addItem(at: "/Documents/Folder")
        let service = Fixtures.service(engine)
        let data = try await service.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))
        let implicitStart = ResolutionPolicy(startsImplicitAccess: true)
        let first = registry.lease(for: "a", resolved: try await service.resolve(data, policy: implicitStart))

        do {
            let late = try await service.resolve(data, policy: implicitStart)
            let shared = registry.lease(for: "a", resolved: late)
            #expect(shared.url == first.url)
            #expect(engine.outstandingAccess["/Documents/Folder"] == 2)
            shared.end()
        }

        #expect(engine.outstandingAccess["/Documents/Folder"] == 1)
        first.end()
        #expect(engine.isBalanced)
    }

    @Test func takesOwnershipOfASystemStartedURL() {
        engine.addItem(at: "/Panel")
        let grant = engine.grant("/Panel", origin: .openPanel)

        let lease = lease("p", grant.url, alreadyStarted: true)

        #expect(engine.calls.starts == 0)
        lease.end()
        #expect(engine.isBalanced)
    }

    @Test func leasesAResolvedBookmarkWithItsOwnScope() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        let resolved = try await Fixtures.service(engine).resolve(data)

        let registered = registry.lease(for: "folder", resolved: resolved)
        let direct = resolved.beginAccess()

        #expect(registered.url == direct.url)
        registered.end()
        #expect(registry.activeKeys.isEmpty)
        #expect(direct.isActive)
        direct.end()
        #expect(engine.isBalanced)
    }

    @Test func oneResolvedBookmarkCanBackSeveralKeys() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        let resolved = try await Fixtures.service(engine).resolve(data)

        let first = registry.lease(for: "first", resolved: resolved)
        let second = registry.lease(for: "second", resolved: resolved)
        #expect(registry.activeKeys == ["first", "second"])

        first.end()
        #expect(registry.activeKeys == ["second"])
        second.end()
        #expect(registry.activeKeys.isEmpty)
        #expect(engine.isBalanced)
    }

    @Test func takesOverAnUnusedImplicitStart() async throws {
        let engine = Fixtures.engine(Fixtures.iOS)
        let registry = AccessRegistry<String>(engine: engine)
        engine.addItem(at: "/Documents/Folder")
        let service = Fixtures.service(engine)
        let data = try await service.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))
        let resolved = try await service.resolve(data, policy: ResolutionPolicy(startsImplicitAccess: true))
        let startsAfterResolution = engine.calls.starts

        let lease = registry.lease(for: "folder", resolved: resolved)
        let second = registry.lease(for: "other", resolved: resolved)

        #expect(engine.calls.starts == startsAfterResolution + 1)
        lease.end()
        second.end()
        #expect(engine.isBalanced)
    }

    @Test func activeLeaseOnlyExistsWhileLeased() {
        let url = issue("/A")
        #expect(registry.activeLease(for: "a") == nil)

        let lease = lease("a", url)
        let extra = registry.activeLease(for: "a")
        #expect(extra?.url == url)
        #expect(engine.calls.starts == 1)

        extra?.end()
        lease.end()
        #expect(registry.activeLease(for: "a") == nil)
        #expect(registry.activeKeys.isEmpty)
    }

    @Test func forgetsKeysOnceIdle() {
        let lease = lease("a", issue("/A"))
        #expect(registry.activeKeys == ["a"])

        lease.end()

        #expect(registry.activeKeys.isEmpty)
        #expect(registry.startedScopeCount == 0)
    }

    @Test func detachedLeasesKeepAccessUntilTheyEnd() {
        let url = issue("/A")
        let old = lease("a", url)

        registry.detach("a")
        let fresh = lease("a", url)

        #expect(old.isActive)
        #expect(engine.calls.starts == 2)
        old.end()
        #expect(fresh.isActive)
        fresh.end()
        #expect(engine.isBalanced)
    }

    @Test func endAllStopsEverythingOnce() {
        let a = lease("a", issue("/A"))
        let a2 = lease("a", issue("/A"))
        let b = lease("b", issue("/B"))

        registry.endAll()

        #expect(engine.isBalanced)
        #expect(!a.isActive && !a2.isActive && !b.isActive)
        #expect(registry.activeKeys.isEmpty)
        a.end()
        a2.end()
        b.end()
        #expect(engine.calls.stops == 2)
        #expect(engine.unbalancedStops.isEmpty)
    }

    @Test func countsStartedScopes() {
        let a = lease("a", issue("/A"))
        engine.refuseAccess(to: "/B")
        let b = lease("b", issue("/B"))

        #expect(registry.startedScopeCount == 1)
        #expect(registry.activeKeys == ["a", "b"])
        a.end()
        b.end()
    }

    @Suite("Covering leases")
    struct Covering {
        let base = AccessRegistryTests()

        func lease(_ key: String, _ path: String) -> AccessLease {
            base.lease(key, base.issue(path))
        }

        @Test func findsTheDeepestActiveAncestor() {
            let outer = lease("outer", "/Users/me")
            let inner = lease("inner", "/Users/me/Projects")

            let covering = base.registry.lease(covering: URL(filePath: "/Users/me/Projects/App/File.swift"))

            #expect(covering?.url == inner.url)
            #expect(base.engine.calls.starts == 2)
            covering?.end()
            outer.end()
            inner.end()
            #expect(base.engine.isBalanced)
        }

        @Test func coversTheItemItself() {
            let root = lease("root", "/Users/me/Projects")

            #expect(base.registry.lease(covering: URL(filePath: "/Users/me/Projects")) != nil)
            root.end()
        }

        @Test func onlyCoversWithEnoughAccess() {
            let readOnly = base.registry.lease(for: "ro", url: base.issue("/Users/me/ReadOnly"), access: .readOnly)
            let reference = base.registry.lease(for: "ref", url: base.issue("/Users/me/Reference"), access: nil)

            #expect(base.registry.lease(covering: URL(filePath: "/Users/me/ReadOnly/File")) == nil)
            #expect(base.registry.lease(covering: URL(filePath: "/Users/me/ReadOnly/File"), access: .readOnly)?.url == readOnly.url)
            #expect(base.registry.lease(covering: URL(filePath: "/Users/me/Reference/File"), access: .readOnly) == nil)
            readOnly.end()
            reference.end()
            #expect(base.engine.isBalanced)
        }

        @Test func aDeeperScopeWithoutEnoughAccessFallsBackToAnAncestor() {
            let outer = lease("outer", "/Users/me")
            let inner = base.registry.lease(for: "inner", url: base.issue("/Users/me/Projects"), access: .readOnly)

            let covering = base.registry.lease(covering: URL(filePath: "/Users/me/Projects/App"))

            #expect(covering?.url == outer.url)
            covering?.end()
            outer.end()
            inner.end()
            #expect(base.engine.isBalanced)
        }

        @Test func ignoresUnrelatedAndIdleItems() {
            lease("idle", "/Users/me/Idle").end()
            let other = lease("other", "/Users/me/Other")

            #expect(base.registry.lease(covering: URL(filePath: "/Users/me/Idle/File")) == nil)
            #expect(base.registry.lease(covering: URL(filePath: "/Users/me/Elsewhere")) == nil)
            other.end()
        }
    }

    @Test func concurrentLeasingStaysBalanced() async {
        let urls = (0..<10).map { issue("/Items/\($0)") }
        let registry = registry
        let engine = engine

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let lease = registry.lease(for: "\(index % 10)", url: urls[index % 10])
                    await Task.yield()
                    lease.end()
                }
            }
        }

        #expect(engine.isBalanced)
        #expect(registry.activeKeys.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func activeLeasesNeverStartAScopeThatIsEnding() async {
        let url = issue("/A")
        let registry = registry
        let rounds = 500

        for _ in 0..<rounds {
            let lease = registry.lease(for: "a", url: url)
            async let ended: Void = lease.end()
            async let joined = registry.activeLease(for: "a")
            await ended
            await joined?.end()
        }

        #expect(engine.calls.starts == rounds)
        #expect(engine.isBalanced)
        #expect(registry.activeKeys.isEmpty)
    }

    @Test func leasingAfterDirectAccessStartsItsOwnScope() async throws {
        let engine = Fixtures.engine(Fixtures.iOS)
        let registry = AccessRegistry<String>(engine: engine)
        engine.addItem(at: "/Documents/Folder")
        let service = Fixtures.service(engine)
        let data = try await service.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))
        let resolved = try await service.resolve(data, policy: ResolutionPolicy(startsImplicitAccess: true))
        let startsAfterResolution = engine.calls.starts

        let direct = resolved.beginAccess()
        let registered = registry.lease(for: "folder", resolved: resolved)

        #expect(engine.calls.starts == startsAfterResolution + 1)
        #expect(engine.outstandingAccess["/Documents/Folder"] == 2)
        direct.end()
        registered.end()
        #expect(engine.isBalanced)
    }

    @Test(.timeLimit(.minutes(1)))
    func endingEverythingWhileLeasesComeAndGoStaysBalanced() async {
        let urls = (0..<6).map { issue("/Items/\($0)") }
        let registry = registry

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<300 {
                group.addTask {
                    if index.isMultiple(of: 25) {
                        registry.endAll()
                    } else {
                        let lease = registry.lease(for: "\(index % 6)", url: urls[index % 6])
                        await Task.yield()
                        lease.end()
                    }
                }
            }
        }
        registry.endAll()

        #expect(engine.isBalanced)
        #expect(engine.unbalancedStops.isEmpty)
        #expect(registry.activeKeys.isEmpty)
    }

    @Test func leasingAgainAfterEndingEverythingStartsAgain() {
        let url = issue("/A")
        let first = lease("a", url)

        registry.endAll()
        let second = lease("a", url)

        #expect(!first.isActive)
        #expect(second.isActive)
        #expect(engine.calls.starts == 2)
        first.end()
        second.end()
        #expect(engine.isBalanced)
    }

    @Test func leasesOutliveTheirRegistry() {
        let engine = Fixtures.engine()
        engine.addItem(at: "/A")
        let url = engine.grant("/A", origin: .fileImporter).url
        var registry: AccessRegistry<String>? = AccessRegistry(engine: engine)
        let lease = registry?.lease(for: "a", url: url)

        registry = nil

        #expect(lease?.isActive == true)
        lease?.end()
        #expect(engine.isBalanced)
    }
}

@Suite("ScopeLedger")
struct ScopeLedgerTests {
    let engine = Fixtures.engine()
    let ledger = ScopeLedger(softLimit: 2)

    func lease<Key>(_ path: String, key: Key, in registry: AccessRegistry<Key>, access: AccessMode? = .readWrite) -> AccessLease {
        engine.addItem(at: path)
        return registry.lease(for: key, url: engine.grant(path, origin: .fileImporter).url, access: access)
    }

    @Test func countsScopesAcrossRegistries() {
        let first = AccessRegistry<Int>(engine: engine, ledger: ledger)
        let second = AccessRegistry<String>(engine: engine, ledger: ledger)

        let leases = [lease("/Items/0", key: 0, in: first), lease("/Items/1", key: "one", in: second)]

        #expect(first.startedScopeCount == 1)
        #expect(ledger.startedScopeCount == 2)
        #expect(!ledger.hasExceededSoftLimit)
        leases.forEach { $0.end() }
        #expect(ledger.startedScopeCount == 0)
        #expect(engine.isBalanced)
    }

    @Test func flagsWhenStartedScopesExceedTheSoftLimit() {
        let first = AccessRegistry<Int>(engine: engine, ledger: ledger)
        let second = AccessRegistry<Int>(engine: engine, ledger: ledger)

        let leases = [lease("/Items/0", key: 0, in: first), lease("/Items/1", key: 1, in: first), lease("/Items/2", key: 2, in: second)]

        #expect(ledger.hasExceededSoftLimit)
        leases.forEach { $0.end() }
        #expect(engine.isBalanced)
    }

    @Test func countsLeasesOnResolvedBookmarks() async throws {
        let service = BookmarkService(engine: engine, executor: Fixtures.executor, ledger: ledger)
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)

        let lease = try await service.resolve(data).beginAccess()

        #expect(ledger.startedScopeCount == 1)
        lease.end()
        #expect(ledger.startedScopeCount == 0)
    }

    @Test func coversFromAnyRegistry() throws {
        let other = AccessRegistry<String>(engine: engine, ledger: ledger)
        let folder = lease("/Users/me/Projects", key: "projects", in: other)

        let covering = try #require(ledger.lease(covering: URL(filePath: "/Users/me/Projects/App/File.swift")))

        #expect(covering.url == folder.url)
        #expect(engine.calls.starts == 1)
        covering.end()
        folder.end()
        #expect(ledger.lease(covering: URL(filePath: "/Users/me/Projects/App")) == nil)
        #expect(engine.isBalanced)
    }

    @Test func onlyCoversWithEnoughAccess() {
        let registry = AccessRegistry<String>(engine: engine, ledger: ledger)
        let readOnly = lease("/Users/me/ReadOnly", key: "ro", in: registry, access: .readOnly)
        let reference = lease("/Users/me/Reference", key: "ref", in: registry, access: nil)

        #expect(ledger.lease(covering: URL(filePath: "/Users/me/ReadOnly/File")) == nil)
        #expect(ledger.lease(covering: URL(filePath: "/Users/me/ReadOnly/File"), access: .readOnly)?.url == readOnly.url)
        #expect(ledger.lease(covering: URL(filePath: "/Users/me/Reference/File"), access: .readOnly) == nil)
        readOnly.end()
        reference.end()
    }

    @Test func invalidatedScopesLeaveTheLedger() {
        let registry = AccessRegistry<String>(engine: engine, ledger: ledger)
        let folder = lease("/Users/me/Projects", key: "projects", in: registry)

        registry.endAll()

        #expect(ledger.startedScopeCount == 0)
        #expect(ledger.lease(covering: URL(filePath: "/Users/me/Projects/App")) == nil)
        #expect(!folder.isActive)
    }

    @Test func coversWithTheDeepestScopeAcrossRegistries() throws {
        let outer = AccessRegistry<String>(engine: engine, ledger: ledger)
        let inner = AccessRegistry<Int>(engine: engine, ledger: ledger)
        let home = lease("/Users/me", key: "home", in: outer)
        let projects = lease("/Users/me/Projects", key: 1, in: inner)

        let covering = try #require(ledger.lease(covering: URL(filePath: "/Users/me/Projects/App/File.swift")))
        let outside = try #require(ledger.lease(covering: URL(filePath: "/Users/me/Notes")))

        #expect(covering.url == projects.url)
        #expect(outside.url == home.url)
        #expect(engine.calls.starts == 2)
        [covering, outside, home, projects].forEach { $0.end() }
        #expect(engine.isBalanced)
    }
}
