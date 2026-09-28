@testable import Bookmarks
import BookmarksTesting
import Foundation
import Synchronization
import Testing

@Suite("DocumentBookmarks: replacing the document")
struct DocumentReplacementTests {
    let engine = Fixtures.engine()
    let service: BookmarkService
    let documents: DocumentBookmarks

    struct WriteFailed: Error {}

    init() {
        engine.addItem(at: "/Users/me/Report.pages", isDirectory: false)
        engine.addItem(at: "/Users/me/Images/chart.png", isDirectory: false)
        engine.addItem(at: "/Users/me/Images/photo.png", isDirectory: false)
        service = Fixtures.service(engine)
        documents = service.documents(anchoredOn: URL(filePath: "/Users/me/Report.pages"))
    }

    func bookmark(_ path: String = "/Users/me/Images/chart.png") async throws -> BookmarkData {
        try await documents.create(for: engine.grant(path, origin: .openPanel))
    }

    func failure(resolving data: BookmarkData) async -> BookmarkFailure? {
        do {
            _ = try await documents.resolve(data)
            return nil
        } catch {
            return error.failure
        }
    }

    @Test func keepsEveryBookmarkWorking() async throws {
        let chart = try await bookmark()
        let photo = try await bookmark("/Users/me/Images/photo.png")
        let identity = engine.fileIdentity(of: documents.document)

        try await documents.replaceDocument(with: Data("saved".utf8))

        #expect(engine.fileIdentity(of: documents.document) != identity, "the document is a new file")
        #expect(try await documents.resolve(chart).displayPath == "/Users/me/Images/chart.png")
        #expect(try await documents.resolve(photo).displayPath == "/Users/me/Images/photo.png")
        #expect(engine.calls.replacements == 1)
        #expect(engine.isBalanced)
    }

    @Test func passesTheWriterARealFileOnTheWay() async throws {
        let data = try await bookmark()
        let written = LockedURLs()

        try await documents.replaceDocument { url in
            try Data("saved".utf8).write(to: url)
            written.append(url)
        }

        let url = try #require(written.values.first)
        #expect(url.lastPathComponent == "Report.pages")
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "the temporary file is cleaned up")
        _ = try await documents.resolve(data)
    }

    @Test func aPlainAtomicWriteLosesTheKey() async throws {
        let data = try await bookmark()

        engine.replaceItem(at: "/Users/me/Report.pages")

        #expect(await failure(resolving: data) == .denied)
    }

    @Test func strippedAttributesLoseTheKey() async throws {
        let data = try await bookmark()

        engine.stripExtendedAttributes(at: "/Users/me/Report.pages")

        #expect(await failure(resolving: data) == .denied)
    }

    @Test func bookmarksMadeAfterTheLossGetANewKey() async throws {
        let old = try await bookmark()
        engine.replaceItem(at: "/Users/me/Report.pages")

        let new = try await bookmark("/Users/me/Images/photo.png")

        #expect(try await documents.resolve(new).displayPath == "/Users/me/Images/photo.png")
        #expect(await failure(resolving: old) == .needsRegrant)
    }

    @Test func movesAndSafeSavesKeepTheKey() async throws {
        let data = try await bookmark()

        engine.replaceItem(at: "/Users/me/Report.pages", keepingExtendedAttributes: true)
        engine.moveItem(from: "/Users/me/Report.pages", to: "/Users/me/Moved.pages")

        let moved = service.documents(anchoredOn: URL(filePath: "/Users/me/Moved.pages"))
        #expect(try await moved.resolve(data).displayPath == "/Users/me/Images/chart.png")
    }

    @Test func aGoneDocumentFailsResolution() async throws {
        let data = try await bookmark()

        engine.removeItem(at: "/Users/me/Report.pages")

        #expect(await failure(resolving: data) == .missing)
    }

    @Test func aWriterThatFailsLeavesTheDocument() async throws {
        let data = try await bookmark()
        let identity = engine.fileIdentity(of: documents.document)

        let error = await #expect(throws: BookmarkError.self) {
            try await documents.replaceDocument { _ in throw WriteFailed() }
        }

        #expect(error?.underlying is WriteFailed)
        #expect(error?.lastKnownPath == "/Users/me/Report.pages")
        #expect(engine.fileIdentity(of: documents.document) == identity)
        _ = try await documents.resolve(data)
    }

    @Test func aWriterThatWritesNothingFails() async {
        let error = await #expect(throws: BookmarkError.self) {
            try await documents.replaceDocument { _ in }
        }

        #expect(error?.failure == .missing)
    }

    @Test func replacingAMissingDocumentFails() async {
        let gone = service.documents(anchoredOn: URL(filePath: "/Users/me/Gone.pages"))

        let error = await #expect(throws: BookmarkError.self) {
            try await gone.replaceDocument(with: Data())
        }

        #expect(error?.failure == .missing)
    }

    @Test func scriptedReplacementFailuresAreClassified() async throws {
        engine.failReplacement(of: "/Users/me/Report.pages", with: FakeErrors.notPermitted, times: 1)

        let error = await #expect(throws: BookmarkError.self) {
            try await documents.replaceDocument(with: Data("x".utf8))
        }
        try await documents.replaceDocument(with: Data("y".utf8))

        #expect(error?.failure == .denied)
        #expect(engine.calls.replacements == 2)
    }

    @Test func clearingScriptedFailuresClearsReplacements() async throws {
        engine.failReplacement(of: "/Users/me/Report.pages", with: FakeErrors.notPermitted)
        engine.clearScriptedFailures(of: "/Users/me/Report.pages")
        try await documents.replaceDocument(with: Data("x".utf8))
        engine.failReplacement(of: "/Users/me/Report.pages", with: FakeErrors.notPermitted)
        engine.clearScriptedFailures()

        try await documents.replaceDocument(with: Data("y".utf8))
    }

    @Test func runsToTheEndWhenTheCallerIsCancelled() async throws {
        let data = try await bookmark()
        let documents = documents
        let started = AsyncGate()

        let saving = Task {
            try await documents.replaceDocument { url in
                started.open()
                Thread.sleep(forTimeInterval: 0.05)
                try Data("saved".utf8).write(to: url)
            }
        }
        await started.wait()
        saving.cancel()
        try await saving.value

        #expect(engine.calls.replacements == 1)
        _ = try await documents.resolve(data)
    }
}

final class LockedURLs: Sendable {
    private let storage = Mutex<[URL]>([])

    func append(_ url: URL) {
        storage.withLock { $0.append(url) }
    }

    var values: [URL] { storage.withLock { $0 } }
}
