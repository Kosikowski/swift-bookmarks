@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("AccessLease")
struct AccessLeaseTests {
    let engine = Fixtures.engine()

    func handle(_ path: String = "/Users/me/Folder", alreadyStarted: Bool = false) -> ScopeHandle {
        engine.addItem(at: path)
        _ = engine.grant(path, origin: .fileImporter)
        return ScopeHandle(url: URL(filePath: path), engine: engine, alreadyStarted: alreadyStarted)
    }

    @Test func startsAccessWhenCreatedAndStopsWhenEnded() {
        let lease = AccessLease(handle: handle())

        #expect(lease.didStartScope)
        #expect(lease.isActive)
        #expect(engine.isAccessing("/Users/me/Folder"))

        lease.end()

        #expect(!lease.isActive)
        #expect(engine.isBalanced)
    }

    @Test func endingTwiceStopsOnce() {
        let lease = AccessLease(handle: handle())

        lease.end()
        lease.end()

        #expect(engine.calls.stops == 1)
        #expect(engine.unbalancedStops.isEmpty)
    }

    @Test func deallocationEndsTheLease() {
        do {
            let lease = AccessLease(handle: handle())
            #expect(lease.isActive)
        }

        #expect(engine.isBalanced)
        #expect(engine.calls.stops == 1)
    }

    @Test func leasesOnOneHandleShareOneStart() {
        let handle = handle()
        let first = AccessLease(handle: handle)
        let second = AccessLease(handle: handle)

        #expect(engine.calls.starts == 1)

        first.end()
        #expect(engine.isAccessing("/Users/me/Folder"))
        #expect(second.isActive)

        second.end()
        #expect(engine.isBalanced)
        #expect(engine.calls.stops == 1)
    }

    @Test func anIdleHandleStartsAgainWhenLeasedAgain() {
        let handle = handle()

        AccessLease(handle: handle).end()
        let again = AccessLease(handle: handle)

        #expect(engine.calls.starts == 2)
        #expect(again.isActive)
        again.end()
        #expect(engine.isBalanced)
    }

    @Test func aRefusedStartIsNotBalancedWithAStop() {
        let handle = handle()
        engine.refuseAccess(to: "/Users/me/Folder")

        let lease = AccessLease(handle: handle)
        lease.end()

        #expect(!lease.didStartScope)
        #expect(engine.calls.stops == 0)
        #expect(engine.isBalanced)
    }

    @Test func adoptsAStartTheSystemAlreadyMade() {
        engine.addItem(at: "/Users/me/Panel")
        let grant = engine.grant("/Users/me/Panel", origin: .openPanel)
        let handle = ScopeHandle(url: grant.url, engine: engine, alreadyStarted: true)

        let lease = AccessLease(handle: handle)

        #expect(lease.didStartScope)
        #expect(engine.calls.starts == 0)
        lease.end()
        #expect(engine.isBalanced)
    }

    @Test func invalidatingAnUnusedAdoptedStartBalancesIt() {
        engine.addItem(at: "/Users/me/Panel")
        let grant = engine.grant("/Users/me/Panel", origin: .openPanel)
        let handle = ScopeHandle(url: grant.url, engine: engine, alreadyStarted: true)

        handle.invalidate()

        #expect(engine.isBalanced)
    }

    @Test func invalidationDeactivatesOutstandingLeases() {
        let handle = handle()
        let lease = AccessLease(handle: handle)

        handle.invalidate()

        #expect(!lease.isActive)
        #expect(engine.isBalanced)
        lease.end()
        #expect(engine.calls.stops == 1)
    }

    @Suite("Descendant URLs")
    struct Descendants {
        let engine = Fixtures.engine()

        func lease(_ path: String) -> AccessLease {
            engine.addItem(at: path)
            _ = engine.grant(path, origin: .fileImporter)
            return AccessLease(handle: ScopeHandle(url: URL(filePath: path, directoryHint: .isDirectory), engine: engine))
        }

        @Test func mapsAChildOntoTheLeasedURL() throws {
            let lease = lease("/Users/me/Project")

            let child = try #require(lease.url(forDescendant: URL(filePath: "/Users/me/Project/Sources/main.swift")))

            #expect(child.path(percentEncoded: false) == "/Users/me/Project/Sources/main.swift")
            #expect(child.absoluteString.hasPrefix(lease.url.absoluteString))
        }

        @Test func mapsTheLeasedItemItself() throws {
            let lease = lease("/Users/me/Project")

            let same = try #require(lease.url(forDescendant: URL(filePath: "/Users/me/Project/")))

            #expect(same == lease.url)
        }

        @Test(arguments: ["/Users/me/Projects/Other", "/Users/me", "/Users/me/Project/../Other"])
        func rejectsItemsOutsideTheLease(_ path: String) {
            let lease = lease("/Users/me/Project")

            #expect(lease.url(forDescendant: URL(filePath: path)) == nil)
        }

        @Test func normalisesDotComponents() {
            let lease = lease("/Users/me/Project")

            #expect(lease.url(forDescendant: URL(filePath: "/Users/me/Project/./Sources/../README.md")) != nil)
        }
    }
}
