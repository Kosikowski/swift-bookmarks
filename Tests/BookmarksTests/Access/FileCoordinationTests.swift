@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("Coordinated file access")
struct FileCoordinationTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swift-bookmarks-coordination-\(UUID().uuidString)", directoryHint: .isDirectory)

    func lease() throws -> AccessLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SystemBookmarkEngine()
        return AccessLease(handle: ScopeHandle(url: directory, engine: engine))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func writesAndReadsItemsInsideTheLease() throws {
        defer { cleanUp() }
        let lease = try lease()
        defer { lease.end() }
        let file = directory.appending(path: "notes.txt")

        try lease.coordinatedWrite(file, options: .forReplacing) { try Data("hello".utf8).write(to: $0) }
        let text = try lease.coordinatedRead(file) { try String(contentsOf: $0, encoding: .utf8) }

        #expect(text == "hello")
    }

    @Test func defaultsToTheLeasedItem() throws {
        defer { cleanUp() }
        let lease = try lease()
        defer { lease.end() }

        let name = try lease.coordinatedRead { $0.lastPathComponent }

        #expect(name == directory.lastPathComponent)
    }

    @Test func refusesItemsOutsideTheLease() throws {
        defer { cleanUp() }
        let lease = try lease()
        defer { lease.end() }
        let outside = FileManager.default.temporaryDirectory.appending(path: "elsewhere.txt")

        #expect(throws: CoordinationError.outsideLease(outside)) {
            try lease.coordinatedRead(outside) { _ in }
        }
        #expect(throws: CoordinationError.outsideLease(outside)) {
            try lease.coordinatedWrite(outside) { _ in }
        }
    }

    @Test func refusesEndedLeases() throws {
        defer { cleanUp() }
        let lease = try lease()
        lease.end()

        #expect(throws: CoordinationError.leaseEnded) { try lease.coordinatedRead { _ in } }
    }

    @Test func propagatesErrorsFromTheBody() throws {
        struct Failure: Error {}
        defer { cleanUp() }
        let lease = try lease()
        defer { lease.end() }

        #expect(throws: Failure.self) { try lease.coordinatedWrite { _ in throw Failure() } }
    }
}

@Suite("BookmarkStore: covering leases")
struct StoreCoveringLeaseTests {
    @Test func leasesTheDeepestStoredFolderContainingTheItem() async throws {
        let harness = StoreHarness(policy: StorePolicy(validators: []))
        try await harness.add("home", "/Users/me")
        try await harness.add("projects", "/Users/me/Projects")

        let lease = try #require(try await harness.store.lease(covering: URL(filePath: "/Users/me/Projects/App/main.swift")))

        #expect(lease.url.path(percentEncoded: false) == "/Users/me/Projects/")
        let file = try #require(lease.url(forDescendant: URL(filePath: "/Users/me/Projects/App/main.swift")))
        #expect(file.path(percentEncoded: false) == "/Users/me/Projects/App/main.swift")
        lease.end()
        #expect(harness.engine.isBalanced)
    }

    @Test func nilWhenNoStoredFolderContainsTheItem() async throws {
        let harness = StoreHarness()
        try await harness.add("projects", "/Users/me/Projects")

        #expect(try await harness.store.lease(covering: URL(filePath: "/Users/me/ProjectsArchive/file")) == nil)
    }
}
