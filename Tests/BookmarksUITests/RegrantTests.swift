import Bookmarks
import BookmarksTesting
@testable import BookmarksUI
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

@Suite("Re-granting from BookmarksUI")
struct RegrantTests {
    let engine = FakeBookmarkEngine(environment: SandboxEnvironment(platform: .macOS, isSandboxed: true))
    let store: BookmarkStore<String, NoMetadata>

    init() {
        store = BookmarkStore(persistence: InMemoryPersistence(), service: BookmarkService(engine: engine, ledger: ScopeLedger()))
    }

    @discardableResult
    func add(_ key: String, _ path: String, isDirectory: Bool = true) async throws -> BookmarkRecord<String, NoMetadata> {
        engine.addItem(at: path, isDirectory: isDirectory)
        return try await store.add(engine.grant(path, origin: .openPanel), key: key)
    }

    func grant(_ path: String, isDirectory: Bool = true) -> Grant {
        engine.addItem(at: path, isDirectory: isDirectory)
        return engine.grant(path, origin: .fileImporter)
    }

    @Suite("Configuration")
    struct Configuration {
        let base = RegrantTests()

        @Test func startsNextToAStoredFolder() async throws {
            try await base.add("folder", "/Users/me/Projects/App")

            let configuration = try await base.store.regrantConfiguration(for: "folder", message: "Find App", prompt: "Grant")

            #expect(configuration.directoryURL?.path(percentEncoded: false) == "/Users/me/Projects/")
            #expect(configuration.allowsFolders)
            #expect(!configuration.allowsFiles)
            #expect(configuration.message == "Find App")
            #expect(configuration.prompt == "Grant")
        }

        @Test func offersFilesForAStoredFile() async throws {
            try await base.add("file", "/Users/me/Notes", isDirectory: false)

            let configuration = try await base.store.regrantConfiguration(for: "file", fileTypes: [.plainText])

            #expect(!configuration.allowsFolders)
            #expect(configuration.allowedContentTypes == [.plainText])
        }

        @Test func asksThePathOfAPathOnlyRecord() async throws {
            base.engine.addItem(at: "/Users/me/Folder.bundle")
            base.engine.addItem(at: "/Users/me/README", isDirectory: false)
            try await base.store.add(pathOnly: URL(filePath: "/Users/me/Folder.bundle"), key: "folder")
            try await base.store.add(pathOnly: URL(filePath: "/Users/me/README"), key: "file")
            try await base.store.add(pathOnly: URL(filePath: "/Users/me/Gone.md"), key: "gone")

            let folder = try await base.store.regrantConfiguration(for: "folder")
            let file = try await base.store.regrantConfiguration(for: "file")
            let gone = try await base.store.regrantConfiguration(for: "gone")

            #expect(folder.allowsFolders, "the item says, not its extension")
            #expect(file.allowsFiles)
            #expect(gone.allowsFiles)
        }

        @Test func unknownKeysFail() async {
            let error = await #expect(throws: BookmarkStoreError<String>.self) {
                try await base.store.regrantConfiguration(for: "nope")
            }

            guard case .notFound("nope") = error else {
                Issue.record("Expected notFound, got \(String(describing: error))")
                return
            }
        }
    }

    @Suite("Picked grants")
    struct PickedGrants {
        let base = RegrantTests()

        @Test func usesTheFirstAndRelinquishesTheRest() async throws {
            try await base.add("a", "/Users/me/A")
            let grants = [base.grant("/Users/me/B"), base.engine.grant("/Users/me/A", origin: .openPanel)]

            let record = try await base.store.regrant("a", withFirstOf: grants)

            #expect(record?.lastKnownPath == "/Users/me/B")
            #expect(grants.allSatisfy { $0.isConsumed })
            #expect(base.engine.isBalanced, "\(base.engine.balanceReport)")
        }

        @Test func nothingPickedChangesNothing() async throws {
            let original = try await base.add("a", "/Users/me/A")

            #expect(try await base.store.regrant("a", withFirstOf: []) == nil)
            #expect(try await base.store.record("a") == original)
        }

        @Test func failuresStillBalanceEveryGrant() async throws {
            let grants = [base.grant("/Users/me/B"), base.engine.grant("/Users/me/B", origin: .openPanel)]

            await #expect(throws: BookmarkStoreError<String>.self) { try await base.store.regrant("nope", withFirstOf: grants) }

            #expect(base.engine.isBalanced, "\(base.engine.balanceReport)")
        }
    }

    @MainActor
    @Suite("SwiftUI session")
    struct Session {
        let base = RegrantTests()
        let options = RegrantRequestOptions(message: "Find it", prompt: "Choose", fileTypes: [.item])

        @Test func preparesTheImporter() async throws {
            try await base.add("a", "/Users/me/A")
            let session = RegrantSession<String, NoMetadata>()

            let failure = await session.prepare("a", in: base.store, options: options)

            #expect(failure == nil)
            #expect(session.isPresenting)
            #expect(session.presented?.key == "a")
            #expect(session.presented?.configuration.message == "Find it")
            #expect(session.presented?.configuration.prompt == "Choose")
        }

        @Test func anUnknownKeyFailsWithoutPresenting() async {
            let session = RegrantSession<String, NoMetadata>()

            let failure = await session.prepare("nope", in: base.store, options: options)

            guard case .failure(.notFound("nope"))? = failure else {
                Issue.record("Expected notFound, got \(String(describing: failure))")
                return
            }
            #expect(!session.isPresenting)
        }

        @Test func finishesWithThePickedItem() async throws {
            try await base.add("a", "/Users/me/A")
            let session = RegrantSession<String, NoMetadata>()
            _ = await session.prepare("a", in: base.store, options: options)

            let outcome = await session.finish("a", with: [base.grant("/Users/me/Moved")], in: base.store)

            #expect(try outcome.get()?.lastKnownPath == "/Users/me/Moved")
            #expect(!session.isPresenting)
            #expect(base.engine.isBalanced)
        }

        @Test func reportsWhatARegrantThrows() async throws {
            let session = RegrantSession<String, NoMetadata>()

            let outcome = await session.finish("nope", with: [base.grant("/Users/me/B")], in: base.store)

            guard case .failure(.notFound("nope")) = outcome else {
                Issue.record("Expected notFound, got \(outcome)")
                return
            }
        }

        @Test func cancellingEndsWithNoRecord() async throws {
            try await base.add("a", "/Users/me/A")
            let session = RegrantSession<String, NoMetadata>()
            _ = await session.prepare("a", in: base.store, options: options)

            let outcome = session.end()

            #expect(try outcome.get() == nil)
            #expect(!session.isPresenting)
        }

        @Test func anImporterFailureIsReported() {
            let session = RegrantSession<String, NoMetadata>()

            let outcome = session.end(failing: CocoaError(.fileReadNoPermission))

            guard case .failure(.bookmark(let error)) = outcome else {
                Issue.record("Expected a bookmark error, got \(outcome)")
                return
            }
            #expect(error.failure == .other(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue))
        }

        @Test func beginsOnlyWithAKey() async throws {
            try await base.add("a", "/Users/me/A")
            let session = RegrantSession<String, NoMetadata>()

            #expect(await session.begin(nil, in: base.store, options: options) == nil)
            #expect(!session.isPresenting)
            #expect(await session.begin("a", in: base.store, options: options) == nil)
            #expect(session.presented?.key == "a")
        }

        @Test func pickedGrantsGoToThePresentedKey() async throws {
            try await base.add("a", "/Users/me/A")
            try await base.add("b", "/Users/me/B")
            let session = RegrantSession<String, NoMetadata>()
            _ = await session.prepare("a", in: base.store, options: options)

            let outcome = await session.picked([base.grant("/Users/me/New")], fallback: "b", in: base.store)

            #expect(try outcome?.get()?.key == "a")
        }

        @Test func pickedGrantsGoToTheFallbackOnceDismissed() async throws {
            try await base.add("b", "/Users/me/B")
            let session = RegrantSession<String, NoMetadata>()

            let outcome = await session.picked([base.grant("/Users/me/New")], fallback: "b", in: base.store)

            #expect(try outcome?.get()?.lastKnownPath == "/Users/me/New")
        }

        @Test func pickedGrantsWithoutAKeyAreRelinquished() async {
            let session = RegrantSession<String, NoMetadata>()
            let grant = base.engine.grant("/Users/me/B", origin: .openPanel)

            let outcome = await session.picked([grant], fallback: nil, in: base.store)

            #expect(outcome == nil)
            #expect(grant.isConsumed)
            #expect(base.engine.isBalanced)
        }

        @Test func dismissingClearsThePresentation() async throws {
            try await base.add("a", "/Users/me/A")
            let session = RegrantSession<String, NoMetadata>()
            _ = await session.prepare("a", in: base.store, options: options)

            session.isPresenting = true
            #expect(session.isPresenting)
            session.isPresenting = false

            #expect(session.presented == nil)
        }
    }

    #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
    @MainActor
    @Test func theDocumentPickerRegrantFailsForAnUnknownKeyWithoutPresenting() async {
        let presenter = UIViewController()

        await #expect(throws: BookmarkStoreError<String>.self) {
            try await store.regrantWithDocumentPicker("missing", from: presenter)
        }
        #expect(presenter.presentedViewController == nil)
    }
    #endif
}

@Suite("SwiftUI file dialogs")
struct FileDialogTests {
    struct Failure: Error {}

    @Test func importerResultsBecomeGrantsOrAFailure() {
        let received = LockedGrants()
        let handlers = ImporterHandlers(onGrants: { received.grants.append(contentsOf: $0) }, onFailure: { _ in received.failures += 1 })

        handlers.complete(.success([URL(filePath: "/a"), URL(filePath: "/b")]))
        handlers.complete(.failure(Failure()))

        #expect(received.grants.map(\.origin) == [.fileImporter, .fileImporter])
        #expect(received.grants.map(\.url) == [URL(filePath: "/a"), URL(filePath: "/b")])
        #expect(received.failures == 1)
    }

    @Test func mapsEveryOptionAFileDialogHas() {
        let configuration = PickerConfiguration(
            message: "Choose a folder",
            prompt: "Allow",
            directoryURL: URL(filePath: "/Users/me"),
            showsHiddenFiles: true
        )

        let options = FileDialogOptions(configuration)

        #expect(options.message == "Choose a folder")
        #expect(options.confirmationLabel == "Allow")
        #expect(options.defaultDirectory == URL(filePath: "/Users/me"))
        #expect(options.browserOptions == [.includeHiddenFiles])
    }

    @Test func defaultsLeaveTheDialogAlone() {
        let options = FileDialogOptions(PickerConfiguration())

        #expect(options.message == nil)
        #expect(options.confirmationLabel == nil)
        #expect(options.defaultDirectory == nil)
        #expect(options.browserOptions.isEmpty)
    }

    /// Builds each modifier's view, which is as far as a test can go without presenting.
    @MainActor
    @Test func theModifiersBuild() {
        let store = BookmarkStore<String, NoMetadata>(persistence: InMemoryPersistence(), service: BookmarkService(engine: FakeBookmarkEngine(), ledger: ScopeLedger()))
        let view = VStack {
            Text("Importer").bookmarkImporter(
                isPresented: .constant(false),
                configuration: PickerConfiguration(message: "Pick", prompt: "Allow", directoryURL: URL(filePath: "/tmp"), showsHiddenFiles: true),
                onGrants: { _ in }
            )
            Text("Re-grant").bookmarkRegrant(of: .constant(nil), in: store, message: "Find it")
            Text("Drop").bookmarkDropDestination { _ in true }
        }

        let renderer = ImageRenderer(content: view.frame(width: 100, height: 100))

        #expect(renderer.cgImage != nil)
    }
}

final class LockedGrants {
    var grants: [Grant] = []
    var failures = 0
}
