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
        registry.lease(for: key, handle: ScopeHandle(url: url, engine: engine, alreadyStarted: alreadyStarted))
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

    @Test func balancesASystemStartedURLThatIsNotNeeded() {
        let url = issue("/A")
        engine.addItem(at: "/Panel")
        let grant = engine.grant("/Panel", origin: .openPanel)

        let first = lease("a", url)
        let second = lease("a", grant.url, alreadyStarted: true)

        #expect(!engine.isAccessing("/Panel"))
        first.end()
        second.end()
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

    @Test func leasesAResolvedBookmarkAndSharesItsStart() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        let resolved = try await Fixtures.service(engine).resolve(data)

        let registered = registry.lease(for: "folder", resolved: resolved)
        let direct = resolved.beginAccess()

        #expect(registered.url == direct.url)
        #expect(engine.calls.starts == 1)
        registered.end()
        #expect(engine.isAccessing("/Users/me/Folder"))
        direct.end()
        #expect(engine.isBalanced)
        #expect(registry.activeKeys.isEmpty)
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
                    let lease = registry.lease(for: "\(index % 10)", handle: ScopeHandle(url: urls[index % 10], engine: engine))
                    await Task.yield()
                    lease.end()
                }
            }
        }

        #expect(engine.isBalanced)
        #expect(registry.activeKeys.isEmpty)
    }
}

@Suite("AccessRegistry soft limit")
struct AccessRegistrySoftLimitTests {
    func leases(_ count: Int, softLimit: Int) -> (FakeBookmarkEngine, AccessRegistry<Int>, [AccessLease]) {
        let engine = Fixtures.engine()
        let registry = AccessRegistry<Int>(engine: engine, softLimit: softLimit)
        let leases = (0..<count).map { index -> AccessLease in
            engine.addItem(at: "/Items/\(index)")
            let url = engine.grant("/Items/\(index)", origin: .fileImporter).url
            return registry.lease(for: index, handle: ScopeHandle(url: url, engine: engine))
        }
        return (engine, registry, leases)
    }

    @Test func flagsWhenStartedScopesExceedTheSoftLimit() {
        let (engine, registry, leases) = leases(3, softLimit: 2)

        #expect(registry.hasExceededSoftLimit)
        leases.forEach { $0.end() }
        #expect(engine.isBalanced)
    }

    @Test func staysQuietBelowTheSoftLimit() {
        let (_, registry, leases) = leases(1, softLimit: 2)

        #expect(!registry.hasExceededSoftLimit)
        leases.forEach { $0.end() }
    }
}
