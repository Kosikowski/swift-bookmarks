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

    @Test func startsOncePerKey() {
        let url = issue("/A")

        let first = registry.lease(for: "a", url: url)
        let second = registry.lease(for: "a", url: url)

        #expect(engine.calls.starts == 1)
        #expect(first.isActive && second.isActive)
        first.end()
        second.end()
        #expect(engine.isBalanced)
    }

    @Test func reusesActiveAccessInsteadOfANewURL() {
        let original = issue("/A")
        let other = issue("/A-copy")

        let first = registry.lease(for: "a", url: original)
        let second = registry.lease(for: "a", url: other)

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

        let first = registry.lease(for: "a", url: url)
        let second = registry.lease(for: "a", url: grant.url, alreadyStarted: true)

        #expect(!engine.isAccessing("/Panel"))
        first.end()
        second.end()
        #expect(engine.isBalanced)
    }

    @Test func takesOwnershipOfASystemStartedURL() {
        engine.addItem(at: "/Panel")
        let grant = engine.grant("/Panel", origin: .openPanel)

        let lease = registry.lease(for: "p", url: grant.url, alreadyStarted: true)

        #expect(engine.calls.starts == 0)
        lease.end()
        #expect(engine.isBalanced)
    }

    @Test func activeLeaseOnlyExistsWhileLeased() {
        let url = issue("/A")
        #expect(registry.activeLease(for: "a") == nil)

        let lease = registry.lease(for: "a", url: url)
        let extra = registry.activeLease(for: "a")
        #expect(extra?.url == url)
        #expect(engine.calls.starts == 1)

        extra?.end()
        lease.end()
        #expect(registry.activeLease(for: "a") == nil)
        #expect(registry.activeKeys.isEmpty)
    }

    @Test func forgetsKeysOnceIdle() {
        let lease = registry.lease(for: "a", url: issue("/A"))
        #expect(registry.activeKeys == ["a"])

        lease.end()

        #expect(registry.activeKeys.isEmpty)
        #expect(registry.startedScopeCount == 0)
    }

    @Test func detachedLeasesKeepAccessUntilTheyEnd() {
        let url = issue("/A")
        let old = registry.lease(for: "a", url: url)

        registry.detach("a")
        let fresh = registry.lease(for: "a", url: url)

        #expect(old.isActive)
        #expect(engine.calls.starts == 2)
        old.end()
        #expect(fresh.isActive)
        fresh.end()
        #expect(engine.isBalanced)
    }

    @Test func endAllStopsEverythingOnce() {
        let a = registry.lease(for: "a", url: issue("/A"))
        let a2 = registry.lease(for: "a", url: issue("/A"))
        let b = registry.lease(for: "b", url: issue("/B"))

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
        let a = registry.lease(for: "a", url: issue("/A"))
        engine.refuseAccess(to: "/B")
        let b = registry.lease(for: "b", url: issue("/B"))

        #expect(registry.startedScopeCount == 1)
        #expect(registry.activeKeys == ["a", "b"])
        a.end()
        b.end()
    }

    @Suite("Covering leases")
    struct Covering {
        let engine = Fixtures.engine()
        let registry: AccessRegistry<String>

        init() {
            registry = AccessRegistry(engine: engine)
        }

        func lease(_ key: String, _ path: String) -> AccessLease {
            engine.addItem(at: path)
            return registry.lease(for: key, url: engine.grant(path, origin: .fileImporter).url)
        }

        @Test func findsTheDeepestActiveAncestor() {
            let outer = lease("outer", "/Users/me")
            let inner = lease("inner", "/Users/me/Projects")

            let covering = registry.lease(covering: URL(filePath: "/Users/me/Projects/App/File.swift"))

            #expect(covering?.url == inner.url)
            #expect(engine.calls.starts == 2)
            covering?.end()
            outer.end()
            inner.end()
            #expect(engine.isBalanced)
        }

        @Test func coversTheItemItself() {
            let root = lease("root", "/Users/me/Projects")

            #expect(registry.lease(covering: URL(filePath: "/Users/me/Projects")) != nil)
            root.end()
        }

        @Test func ignoresUnrelatedAndIdleItems() {
            lease("idle", "/Users/me/Idle").end()
            let other = lease("other", "/Users/me/Other")

            #expect(registry.lease(covering: URL(filePath: "/Users/me/Idle/File")) == nil)
            #expect(registry.lease(covering: URL(filePath: "/Users/me/Elsewhere")) == nil)
            other.end()
        }
    }

    @Test func concurrentLeasingStaysBalanced() async {
        let urls = (0..<10).map { issue("/Items/\($0)") }

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
}

@Suite("AccessRegistry soft limit")
struct AccessRegistrySoftLimitTests {
    @Test func flagsWhenStartedScopesExceedTheSoftLimit() {
        let engine = Fixtures.engine()
        let registry = AccessRegistry<Int>(engine: engine, softLimit: 2)
        let leases = (0..<3).map { index -> AccessLease in
            engine.addItem(at: "/Items/\(index)")
            return registry.lease(for: index, url: engine.grant("/Items/\(index)", origin: .fileImporter).url)
        }

        #expect(registry.hasExceededSoftLimit)
        leases.forEach { $0.end() }
        #expect(engine.isBalanced)
    }

    @Test func staysQuietBelowTheSoftLimit() {
        let engine = Fixtures.engine()
        let registry = AccessRegistry<Int>(engine: engine, softLimit: 2)
        engine.addItem(at: "/Items/0")

        let lease = registry.lease(for: 0, url: engine.grant("/Items/0", origin: .fileImporter).url)

        #expect(!registry.hasExceededSoftLimit)
        lease.end()
    }
}
