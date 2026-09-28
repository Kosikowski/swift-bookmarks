import Bookmarks
import Foundation
import Testing

/// App-scoped bookmarks and stores in a sandboxed app, with real files.
@Suite("App-scoped bookmarks in the sandbox")
struct AppScopeTests {
    let folder: SandboxFolder
    let service = BookmarkService.hosted

    init() throws {
        folder = try SandboxFolder()
    }

    func store(policy: StorePolicy = .default) -> BookmarkStore<String, NoMetadata> {
        BookmarkStore(persistence: InMemoryPersistence(), policy: policy, service: service)
    }

    @Test func aDeletedItemIsMissing() async throws {
        defer { folder.remove() }
        let file = try folder.file("Notes.md")
        let data = try await service.create(for: .reachable(file))

        try FileManager.default.removeItem(at: file)

        let error = await #expect(throws: BookmarkError.self) { try await service.resolve(data) }
        #expect(error?.failure == .missing)
        #expect((error?.underlying as? NSError)?.code == NSFileReadCorruptFileError)
    }

    @Test func aStoreDropsDeletedItemsWhenItsPolicySays() async throws {
        defer { folder.remove() }
        let store = store(policy: StorePolicy(failureHandling: .dropMissing))
        let evictions = store.evictions()
        let project = try folder.folder("Project")
        try await store.add(.reachable(project), key: "project")

        try FileManager.default.removeItem(at: project)
        _ = try? await store.lease("project")

        var iterator = evictions.makeAsyncIterator()
        #expect(await iterator.next()?.reason == .failure(.missing))
        #expect(store.snapshot.isEmpty)
    }

    @Test func aRenamedFolderIsFollowedAndRefreshed() async throws {
        defer { folder.remove() }
        let store = store()
        let project = try folder.folder("Project")
        try await store.add(.reachable(project), key: "project")
        let original = try #require(store.snapshot["project"])

        try FileManager.default.moveItem(at: project, to: folder.url("Renamed"))
        let lease = try await store.lease("project")
        defer { lease.end() }

        let record = try #require(store.snapshot["project"])
        #expect(lease.didStartScope)
        #expect(record.lastKnownPath.hasSuffix("/Renamed"))
        #expect(record.data != original.data)
        #expect(record.fileIdentity == original.fileIdentity)
    }

    @Test func goneItemsAreEvictedFirst() async throws {
        defer { folder.remove() }
        let store = store(policy: StorePolicy(limit: 2, eviction: .goneFirst))
        try await store.add(.reachable(try folder.file("A")), key: "a")
        try await store.add(.reachable(try folder.file("B")), key: "b")
        try FileManager.default.removeItem(at: folder.url("B"))
        try await store.refreshStatuses(includingAvailable: true)

        try await store.add(.reachable(try folder.file("C")), key: "c")

        #expect(store.snapshot.keys == ["a", "c"])
    }

    @Test func aPathOnlyRecordGetsItsBookmarkWhenTheItemIsReachable() async throws {
        defer { folder.remove() }
        let store = store()
        let file = try folder.file("Known by path.json")
        try await store.add(pathOnly: file, key: "file")

        try await store.withAccess(to: "file") { url in
            #expect(folder.contents(of: url) == "contents")
        }

        #expect(store.snapshot["file"]?.hasBookmark == true)
        try FileManager.default.moveItem(at: file, to: folder.url("Renamed.json"))
        try await store.lease("file").end()
        #expect(store.snapshot["file"]?.lastKnownPath.hasSuffix("/Renamed.json") == true)
    }

    @Test func oneUseOfAGrantMakesNoBookmark() async throws {
        defer { folder.remove() }
        let destination = try folder.folder("Save as Project")

        try await service.withAccess(to: .reachable(destination)) { url in
            try Data("project".utf8).write(to: url.appending(path: "Project.braceform"))
        }

        #expect(folder.contents(of: destination.appending(path: "Project.braceform")) == "project")
    }
}
