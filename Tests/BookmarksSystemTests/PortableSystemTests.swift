@testable import Bookmarks
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

/// Real files, on every platform the tests run on: macOS through `swift test`, and the iOS
/// simulator. Neither is the App Sandbox of a Mac app; the integration host covers that.
@Suite("System: replacing items")
struct ReplacingTests {
    let sandbox = TemporaryDirectory()
    let engine = SystemBookmarkEngine()
    static let attribute = "dev.swiftbookmarks.test"

    func setAttribute(on url: URL) throws {
        let value = Array("key".utf8)
        guard setxattr(url.path(percentEncoded: false), Self.attribute, value, value.count, 0, 0) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }

    func hasAttribute(_ url: URL) -> Bool {
        getxattr(url.path(percentEncoded: false), Self.attribute, nil, 0, 0, 0) > 0
    }

    func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func replacingKeepsExtendedAttributesWhereAnAtomicWriteDoesnt() throws {
        defer { sandbox.remove() }
        let replaced = try sandbox.makeFile("Replaced.txt", contents: "one")
        let written = try sandbox.makeFile("Written.txt", contents: "one")
        try setAttribute(on: replaced)
        try setAttribute(on: written)
        let before = engine.fileIdentity(of: replaced)

        try engine.replaceItem(at: replaced) { url in try Data("two".utf8).write(to: url) }
        try Data("two".utf8).write(to: written, options: .atomic)

        #expect(try contents(of: replaced) == "two")
        #expect(engine.fileIdentity(of: replaced) != before, "a new file took its place")
        #expect(hasAttribute(replaced))
        #expect(!hasAttribute(written))
    }

    @Test func theTemporaryFileGoesAway() throws {
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("File.txt", contents: "one")
        var temporary: URL?

        try engine.replaceItem(at: file) { url in
            temporary = url
            try Data("two".utf8).write(to: url)
        }

        let used = try #require(temporary)
        #expect(used.lastPathComponent == "File.txt")
        #expect(!FileManager.default.fileExists(atPath: used.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test func aFailingWriterLeavesTheItem() throws {
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("File.txt", contents: "one")
        struct WriteFailed: Error {}

        #expect(throws: WriteFailed.self) { try engine.replaceItem(at: file) { _ in throw WriteFailed() } }

        #expect(try contents(of: file) == "one")
    }

    @Test func documentsAreReplacedWithTheirAttributes() async throws {
        defer { sandbox.remove() }
        let document = try sandbox.makeFile("Project.braceform", contents: "one")
        try setAttribute(on: document)
        let documents = BookmarkService(engine: engine).documents(anchoredOn: document)

        try await documents.replaceDocument(with: Data("two".utf8))

        #expect(try contents(of: document) == "two")
        #expect(hasAttribute(document))
    }

    @Test func aWriterThatWritesNothingFails() async throws {
        defer { sandbox.remove() }
        let document = try sandbox.makeFile("Project.braceform", contents: "one")

        let error = await #expect(throws: BookmarkError.self) {
            try await BookmarkService(engine: engine).documents(anchoredOn: document).replaceDocument { _ in }
        }

        #expect(error?.lastKnownPath == document.path(percentEncoded: false))
        #expect(try contents(of: document) == "one")
    }
}

@Suite("System: whether items exist")
struct ItemExistenceTests {
    let sandbox = TemporaryDirectory()
    let engine = SystemBookmarkEngine()

    @Test func tellsPresentFromAbsent() throws {
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("File.txt", contents: "x")
        let link = sandbox.url("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sandbox.url("Nowhere"))

        #expect(engine.itemExists(atPath: file.path(percentEncoded: false)) == true)
        #expect(engine.itemExists(atPath: link.path(percentEncoded: false)) == true, "a link is an item, wherever it points")
        #expect(engine.itemExists(atPath: sandbox.url("Gone").path(percentEncoded: false)) == false)
        #expect(engine.itemExists(atPath: file.appending(path: "Inside").path(percentEncoded: false)) == false)
    }

    @Test(.disabled(if: getuid() == 0, "File permissions don't restrict root"))
    func cantTellInsideAFolderItCantSearch() throws {
        defer { sandbox.remove() }
        let locked = try sandbox.makeDirectory("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false)) }

        #expect(engine.itemExists(atPath: locked.appending(path: "Inside").path(percentEncoded: false)) == nil)
    }

    @Test func findsAnItemByIdentityAfterItMoved() throws {
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("File.txt", contents: "x")
        let identity = try #require(engine.fileIdentity(of: file))

        try FileManager.default.moveItem(at: file, to: sandbox.url("Renamed.txt"))

        #if os(macOS)
        #expect(engine.itemExists(withIdentity: identity) == true)
        try FileManager.default.removeItem(at: sandbox.url("Renamed.txt"))
        #expect(engine.itemExists(withIdentity: identity) == false)
        #else
        #expect(engine.itemExists(withIdentity: identity) == nil)
        #endif
        #expect(engine.itemExists(withIdentity: FileIdentity(volumeUUID: UUID().uuidString, fileID: identity.fileID)) == nil)
    }
}

@Suite("System: stores with real files")
struct PortableStoreTests {
    let sandbox = TemporaryDirectory()
    let service = BookmarkService(engine: SystemBookmarkEngine(), executor: BlockingExecutor(label: "portable-system-tests", width: 4), ledger: ScopeLedger())

    func store(policy: StorePolicy = .default) -> BookmarkStore<String, NoMetadata> {
        BookmarkStore(persistence: InMemoryPersistence(), policy: policy, service: service)
    }

    func grant(_ url: URL) -> Grant {
        Grant(url: url, origin: .alreadyAccessible)
    }

    @Test func usesThePlatformsKind() {
        #expect(service.defaultKind == .persistentDefault(for: .current))
    }

    @Test func renamedFoldersAreFollowedAndRefreshed() async throws {
        defer { sandbox.remove() }
        let store = store()
        let folder = try sandbox.makeDirectory("Before")
        let original = try await store.add(grant(folder), key: "folder")
        let renamed = sandbox.url("After")

        try FileManager.default.moveItem(at: folder, to: renamed)
        let path = try await store.withAccess(to: "folder") { sandbox.canonical($0) }

        let record = try #require(store.snapshot["folder"])
        #expect(path == sandbox.canonical(renamed))
        #expect(record.data != original.data)
        #expect(record.lastKnownPath.hasSuffix("/After"))
        #expect(record.fileIdentity == original.fileIdentity)
    }

    @Test func atomicallySavedFilesStillResolve() async throws {
        defer { sandbox.remove() }
        let store = store()
        let file = try sandbox.makeFile("Notes.md", contents: "one")
        try await store.add(grant(file), key: "notes")

        try Data("two".utf8).write(to: file, options: .atomic)
        let contents = try await store.withAccess(to: "notes") { try String(contentsOf: $0, encoding: .utf8) }

        #expect(contents == "two")
    }

    @Test func pathOnlyRecordsGetABookmarkAndThenFollowTheItem() async throws {
        defer { sandbox.remove() }
        let store = store()
        let file = try sandbox.makeFile("Known.json", contents: "{}")
        try await store.add(pathOnly: file, key: "file")
        #expect(store.snapshot["file"]?.hasBookmark == false)
        #expect(try await store.availability("file") == .available)

        let contents = try await store.withAccess(to: "file") { try String(contentsOf: $0, encoding: .utf8) }
        try FileManager.default.moveItem(at: file, to: sandbox.url("Moved.json"))
        try await store.lease("file").end()

        #expect(contents == "{}")
        #expect(store.snapshot["file"]?.hasBookmark == true)
        #expect(store.snapshot["file"]?.lastKnownPath.hasSuffix("/Moved.json") == true)
    }

    @Test func aMissingPathOnlyItemIsMissing() async throws {
        defer { sandbox.remove() }
        _ = try sandbox.makeDirectory("Folder")
        let store = store()
        try await store.add(pathOnly: sandbox.url("Folder/Gone.json"), key: "gone")

        let error = await #expect(throws: BookmarkStoreError<String>.self) { try await store.lease("gone") }

        #expect(error?.bookmarkFailure == .missing)
        #expect(store.snapshot["gone"]?.isGone == true)
    }

    @Test func deletedItemsAreFoundAndEvictedFirst() async throws {
        defer { sandbox.remove() }
        let store = store(policy: StorePolicy(limit: 2, eviction: .goneFirst))
        let evictions = store.evictions()
        try await store.add(grant(try sandbox.makeFile("A", contents: "a")), key: "a")
        try await store.add(grant(try sandbox.makeFile("B", contents: "b")), key: "b")
        try FileManager.default.removeItem(at: sandbox.url("A"))

        try await store.refreshStatuses(includingAvailable: true)
        try await store.add(grant(try sandbox.makeFile("C", contents: "c")), key: "c")

        var iterator = evictions.makeAsyncIterator()
        let eviction = await iterator.next()
        #expect(eviction?.key == "a")
        #expect(eviction?.record.isGone == true)
        #expect(store.snapshot.keys == ["b", "c"])
    }

    @Test func aGrantCanBeUsedOnceWithoutABookmark() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Destination")

        let written = try await service.withAccess(to: Grant(url: folder, origin: .fileImporter)) { url in
            let file = url.appending(path: "Project.braceform")
            try Data("project".utf8).write(to: file)
            return file
        }

        #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
        #expect(service.ledger.startedScopeCount == 0)
    }

    #if os(macOS)
    @Test func itemsMovedToTheTrashAreGone() async throws {
        defer { sandbox.remove() }
        let store = store()
        let file = try sandbox.makeFile("Trashed \(UUID().uuidString).txt", contents: "x")
        try await store.add(grant(file), key: "trashed")
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        } catch {
            // Some volumes have no Trash; nothing to check there.
            return
        }
        defer { (trashed as URL?).map { try? FileManager.default.removeItem(at: $0) } }

        try await store.refreshStatuses(includingAvailable: true)

        let record = try #require(store.snapshot["trashed"])
        #expect(record.status == .available)
        #expect(record.isInTrash)
        #expect(record.isGone)
    }
    #endif
}
