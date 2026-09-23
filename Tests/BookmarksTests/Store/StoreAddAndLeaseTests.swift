@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: adding and leasing in one step")
struct StoreAddAndLeaseTests {
    let harness = StoreHarness()

    @Test func leasesWithTheResolutionAdoptingMade() async throws {
        let grant = harness.grant("/Users/me/Notes")
        let before = harness.engine.calls.resolutions

        let (record, lease) = try await harness.store.addAndLease(grant, key: "notes", metadata: Tag(name: "Notes"))

        #expect(harness.engine.calls.resolutions == before + 1, "adopting resolves once, and the lease reuses it")
        #expect(record.key == "notes")
        #expect(lease.isActive)
        #expect(harness.engine.isAccessing("/Users/me/Notes"))
        #expect(harness.store.activeLease(for: "notes") != nil)
        lease.end()
        #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
    }

    @Test func aSecondLeaseJoinsTheFirst() async throws {
        let (_, first) = try await harness.store.addAndLease(harness.grant("/Users/me/Notes"), key: "notes", metadata: Tag(name: "Notes"))
        let starts = harness.engine.calls.starts

        let second = try await harness.store.lease("notes")

        #expect(harness.engine.calls.starts == starts)
        first.end()
        second.end()
        #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
    }

    @Test func replacingAKeyLeasesTheNewItem() async throws {
        let (_, old) = try await harness.store.addAndLease(harness.grant("/Users/me/Old"), key: "folder", metadata: Tag(name: "Old"))

        let (record, new) = try await harness.store.addAndLease(harness.grant("/Users/me/New"), key: "folder", metadata: Tag(name: "New"))

        #expect(record.lastKnownPath == "/Users/me/New")
        #expect(new.url.path(percentEncoded: false).hasPrefix("/Users/me/New"))
        old.end()
        #expect(!harness.engine.isAccessing("/Users/me/Old"))
        #expect(harness.engine.isAccessing("/Users/me/New"))
        new.end()
        #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
    }

    @Test func aDuplicateUnderTheRecentsPolicyLeasesTheRecordAlreadyThere() async throws {
        let harness = StoreHarness(policy: .recents(limit: 8))
        try await harness.add("first", "/Users/me/Notes")

        let (record, lease) = try await harness.store.addAndLease(harness.grant("/Users/me/Notes"), key: "second", metadata: Tag(name: "Again"))

        #expect(record.key == "first")
        #expect(harness.store.activeLease(for: "first") != nil)
        #expect(harness.store.activeLease(for: "second") == nil)
        lease.end()
        #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
    }

    @Test func aGrantThatCannotBeAdoptedLeavesNothingBehind() async throws {
        harness.engine.addItem(at: "/Users/me/Locked")
        harness.engine.failCreation(of: "/Users/me/Locked", with: CocoaError(.fileReadNoPermission) as NSError)

        await #expect(throws: BookmarkStoreError<String>.self) {
            try await harness.store.addAndLease(harness.engine.grant("/Users/me/Locked", origin: .openPanel), key: "locked", metadata: Tag(name: "Locked"))
        }
        #expect(try await harness.store.records().isEmpty)
        #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
    }
}
