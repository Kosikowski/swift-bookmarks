@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: copying from another store")
struct StoreCopyTests {
    let harness = StoreHarness()

    private func otherStore(policy: StorePolicy = .default) -> BookmarkStore<Int, NoMetadata> {
        BookmarkStore(persistence: InMemoryPersistence(), policy: policy, service: Fixtures.service(harness.engine))
    }

    @Test func takesTheBookmarkAsItIsWithoutResolvingIt() async throws {
        let original = try await harness.add("a", "/Users/me/A")
        let other = otherStore()
        let resolutions = harness.engine.calls.resolutions

        let copy = try await other.add(copyOf: original, key: 1, metadata: NoMetadata())

        #expect(copy.data == original.data)
        #expect(copy.kind == original.kind)
        #expect(copy.lastKnownPath == original.lastKnownPath)
        #expect(copy.fileIdentity == original.fileIdentity)
        #expect(harness.engine.calls.resolutions == resolutions)
        try await other.lease(1).end()
        #expect(harness.engine.isBalanced, "\(harness.engine.balanceReport)")
    }

    @Test func anItemThatCannotBeReachedMovesToo() async throws {
        let original = try await harness.add("a", "/Users/me/A")
        harness.engine.removeItem(at: "/Users/me/A")
        _ = try? await harness.store.lease("a")
        let unavailable = try #require(try await harness.store.record("a"))

        let copy = try await otherStore().add(copyOf: unavailable, key: 1, metadata: NoMetadata())

        #expect(copy.data == original.data)
        #expect(copy.status.failure == .missing)
    }

    @Test func anItemAlreadyStoredIsADuplicate() async throws {
        let original = try await harness.add("a", "/Users/me/A")
        let other = otherStore()
        try await other.add(copyOf: original, key: 1, metadata: NoMetadata())

        do {
            try await other.add(copyOf: original, key: 2, metadata: NoMetadata())
            Issue.record("a second copy of the same item was stored")
        } catch {
            guard case .duplicate(of: 1) = error else { Issue.record("\(error)"); return }
        }
        #expect(try await other.keys() == [1])
    }

    @Test func implicitBookmarksAreNotKeptOnTheMac() async throws {
        let implicit = TestRecord(
            key: "a",
            data: BookmarkData(Data("a".utf8)),
            kind: .implicit,
            lastKnownPath: "/Users/me/A",
            fileIdentity: nil,
            status: .unknown,
            createdAt: Date(),
            metadata: Tag(name: "a")
        )

        do {
            try await otherStore().add(copyOf: implicit, key: 1, metadata: NoMetadata())
            Issue.record("an implicit bookmark was kept")
        } catch {
            guard case .unsupported? = error.bookmarkFailure else { Issue.record("\(error)"); return }
        }
    }

    @Test func aCopyOfAnItemAlreadyStoredUpdatesItUnderTheRecentsPolicy() async throws {
        let original = try await harness.add("a", "/Users/me/A")
        let other = otherStore(policy: .recents(limit: 8))
        let first = try await other.add(copyOf: original, key: 1, metadata: NoMetadata())
        harness.engine.removeItem(at: "/Users/me/A")
        _ = try? await harness.store.lease("a")
        let unavailable = try #require(try await harness.store.record("a"))

        let merged = try await other.add(copyOf: unavailable, key: 2, metadata: NoMetadata())

        #expect(merged.key == first.key)
        #expect(merged.status.failure == .missing, "the copy's status is kept, not assumed")
        #expect(try await other.keys() == [1])
    }

    @Test func aCopyUnderAKeyAlreadyUsedReplacesItAndKeepsItsCreationDate() async throws {
        let first = try await harness.add("a", "/Users/me/A")
        let second = try await harness.add("b", "/Users/me/B")
        let other = otherStore()
        let kept = try await other.add(copyOf: first, key: 1, metadata: NoMetadata())

        let replaced = try await other.add(copyOf: second, key: 1, metadata: NoMetadata())

        #expect(replaced.lastKnownPath == "/Users/me/B")
        #expect(replaced.createdAt == kept.createdAt)
        #expect(try await other.keys() == [1])
    }

    @Test func aCopyIsSaved() async throws {
        let original = try await harness.add("a", "/Users/me/A")
        let persistence = InMemoryPersistence<Int, NoMetadata>()
        let other = BookmarkStore(persistence: persistence, service: Fixtures.service(harness.engine))

        try await other.add(copyOf: original, key: 1, metadata: NoMetadata())

        #expect(try persistence.load().map(\.data) == [original.data])
    }
}
