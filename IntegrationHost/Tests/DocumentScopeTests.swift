import AppKit
import Bookmarks
import Foundation
import Testing

/// Document-scoped bookmarks in a sandboxed app with the document-scope entitlement: what
/// keeps their key and what loses it (docs/research/README.md §3, "Document-scoped bookmarks
/// and saving the anchor").
@Suite("Document-scoped bookmarks in the sandbox")
struct DocumentScopeTests {
    let folder: SandboxFolder
    let service = BookmarkService.hosted
    let document: URL
    let target: URL
    let documents: DocumentBookmarks

    init() throws {
        folder = try SandboxFolder()
        document = try folder.file("Project.braceform", "project")
        target = try folder.file("Images/chart.png", "chart")
        documents = service.documents(anchoredOn: document)
    }

    func bookmark(_ url: URL? = nil) async throws -> BookmarkData {
        try await documents.create(for: .reachable(url ?? target))
    }

    func failure(resolving data: BookmarkData, in documents: DocumentBookmarks? = nil) async -> BookmarkFailure? {
        do {
            _ = try await (documents ?? self.documents).resolve(data)
            return nil
        } catch {
            return error.failure
        }
    }

    @Test func runsSandboxed() {
        defer { folder.remove() }

        #expect(service.environment.isSandboxed)
        #expect(service.defaultKind == .appScoped(.readWrite))
    }

    @Test func createsAndResolvesBookmarksWithAccess() async throws {
        defer { folder.remove() }
        let data = try await bookmark()

        let resolved = try await documents.resolve(data)
        let lease = resolved.beginAccess()
        defer { lease.end() }

        #expect(!resolved.wasStale)
        #expect(resolved.displayPath.hasSuffix("/Images/chart.png"))
        #expect(lease.didStartScope)
        #expect(folder.contents(of: lease.url) == "chart")
    }

    @Test func aPlainAtomicWriteLosesTheKey() async throws {
        defer { folder.remove() }
        let data = try await bookmark()

        try Data("saved".utf8).write(to: document, options: .atomic)

        #expect(await failure(resolving: data) == .denied)
    }

    @Test func replaceDocumentKeepsTheKey() async throws {
        defer { folder.remove() }
        let data = try await bookmark()
        let before = folder.fileID(of: document)

        try await documents.replaceDocument(with: Data("saved".utf8))

        #expect(folder.fileID(of: document) != before, "the document is a new file")
        #expect(folder.contents(of: document) == "saved")
        #expect(try await documents.resolve(data).displayPath.hasSuffix("/Images/chart.png"))
    }

    @Test func fileManagersReplaceKeepsTheKey() async throws {
        defer { folder.remove() }
        let data = try await bookmark()
        let replacement = try folder.file("Replacement", "saved")

        _ = try FileManager.default.replaceItemAt(document, withItemAt: replacement)

        #expect(await failure(resolving: data) == nil)
    }

    @MainActor
    @Test func nsDocumentsSafeSaveKeepsTheKey() async throws {
        defer { folder.remove() }
        // A plain-text document, so NSDocument keeps its name.
        let notes = try folder.file("Notes.txt", "notes")
        let documents = service.documents(anchoredOn: notes)
        let data = try await documents.create(for: .reachable(target))
        let before = folder.fileID(of: notes)
        let saved = try TextDocument(contentsOf: notes, ofType: "public.plain-text")
        saved.text = "saved"

        try await saved.save(to: notes, ofType: "public.plain-text", for: .saveOperation)

        #expect(folder.fileID(of: notes) != before, "a safe save writes a new file")
        #expect(folder.contents(of: notes) == "saved")
        #expect(await failure(resolving: data, in: documents) == nil)
    }

    @Test func writingInPlaceKeepsTheKey() async throws {
        defer { folder.remove() }
        let data = try await bookmark()

        let handle = try FileHandle(forWritingTo: document)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("saved".utf8))
        try handle.close()

        #expect(await failure(resolving: data) == nil)
    }

    @Test func movedAndCopiedDocumentsKeepTheirBookmarks() async throws {
        defer { folder.remove() }
        let data = try await bookmark()
        let moved = folder.url("Moved.braceform")
        let copy = folder.url("Copy.braceform")

        try FileManager.default.moveItem(at: document, to: moved)
        try FileManager.default.copyItem(at: moved, to: copy)

        #expect(await failure(resolving: data, in: service.documents(anchoredOn: moved)) == nil)
        #expect(await failure(resolving: data, in: service.documents(anchoredOn: copy)) == nil)
    }

    @Test func bookmarksMadeAfterTheLossGetANewKey() async throws {
        defer { folder.remove() }
        let old = try await bookmark()
        try Data("saved".utf8).write(to: document, options: .atomic)
        let photo = try folder.file("Images/photo.png", "photo")

        let new = try await bookmark(photo)

        #expect(await failure(resolving: new) == nil)
        #expect(await failure(resolving: old) == .needsRegrant)
    }

    @Test func anotherDocumentDoesntResolveThem() async throws {
        defer { folder.remove() }
        let data = try await bookmark()
        let other = service.documents(anchoredOn: try folder.file("Other.braceform"))

        let withoutKey = await failure(resolving: data, in: other)
        _ = try await other.create(for: .reachable(try folder.file("Images/other.png")))
        let withKey = await failure(resolving: data, in: other)

        #expect(withoutKey == .denied)
        #expect(withKey == .needsRegrant)
    }

    @Test func aRenamedTargetIsStaleAndRefreshedInsideItsScope() async throws {
        defer { folder.remove() }
        let data = try await bookmark()
        try FileManager.default.moveItem(at: target, to: folder.url("Images/renamed.png"))

        let resolved = try await documents.resolve(data)

        #expect(resolved.wasStale)
        #expect(resolved.refreshError == nil)
        let refreshed = try #require(resolved.refreshedData)
        let again = try await documents.resolve(refreshed)
        #expect(!again.wasStale)
        #expect(again.displayPath.hasSuffix("/Images/renamed.png"))
    }

    @Test func anAtomicallySavedTargetStillResolves() async throws {
        defer { folder.remove() }
        let data = try await bookmark()

        try Data("new chart".utf8).write(to: target, options: .atomic)

        let resolved = try await documents.resolve(data)
        #expect(resolved.wasStale)
        #expect(resolved.displayPath.hasSuffix("/Images/chart.png"))
    }

    @Test func aDeletedTargetIsMissing() async throws {
        defer { folder.remove() }
        let data = try await bookmark()

        try FileManager.default.removeItem(at: target)

        let error = await #expect(throws: BookmarkError.self) { try await documents.resolve(data) }
        #expect(error?.failure == .missing)
        // The sandbox reports it as it reports a scope key that doesn't match.
        #expect((error?.underlying as? NSError)?.code == NSFileReadCorruptFileError)
    }

    @Test func targetsInTheContainerAreRefused() async throws {
        defer { folder.remove() }
        let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "swift-bookmarks-\(UUID().uuidString).png")
        try Data("png".utf8).write(to: container)
        defer { try? FileManager.default.removeItem(at: container) }

        let error = await #expect(throws: BookmarkError.self) { try await documents.create(for: .reachable(container)) }

        #expect(error?.failure == .denied)
    }
}

final class TextDocument: NSDocument {
    var text = ""

    override class var autosavesInPlace: Bool { false }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        text = String(decoding: data, as: UTF8.self)
    }
}
