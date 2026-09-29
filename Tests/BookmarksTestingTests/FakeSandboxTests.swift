import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("FakeBookmarkEngine: deletions and document keys")
struct FakeSandboxTests {
    let engine = FakeBookmarkEngine(environment: .sandboxedMac)

    func bookmark(_ path: String, options: URL.BookmarkCreationOptions = [.scope], document: String? = nil, engine: FakeBookmarkEngine? = nil) throws -> BookmarkData {
        let engine = engine ?? self.engine
        engine.addItem(at: path, isDirectory: false)
        engine.makeAccessibleWithoutGrant(path)
        return try engine.makeBookmark(for: URL(filePath: path), options: options, includingResourceValuesFor: [], relativeTo: document.map { URL(filePath: $0) })
    }

    func code(resolving data: BookmarkData, options: URL.BookmarkResolutionOptions = [.scope], document: String? = nil, engine: FakeBookmarkEngine? = nil) -> Int? {
        do {
            _ = try (engine ?? self.engine).resolve(data, options: options, relativeTo: document.map { URL(filePath: $0) })
            return nil
        } catch {
            return (error as NSError).code
        }
    }

    @Test func aDeletedScopedItemIsCorruptInTheSandbox() throws {
        let data = try bookmark("/f")

        engine.removeItem(at: "/f")

        #expect(code(resolving: data) == NSFileReadCorruptFileError)
    }

    @Test func aDeletedReferenceIsMissingInTheSandbox() throws {
        let data = try bookmark("/f", options: [.withoutImplicitSecurityScope])

        engine.removeItem(at: "/f")

        #expect(code(resolving: data, options: []) == NSFileNoSuchFileError)
    }

    @Test func aDeletedScopedItemIsMissingOutsideTheSandbox() throws {
        let engine = FakeBookmarkEngine(environment: SandboxEnvironment(platform: .macOS, isSandboxed: false))
        let data = try bookmark("/f", engine: engine)

        engine.removeItem(at: "/f")

        #expect(code(resolving: data, engine: engine) == NSFileNoSuchFileError)
    }

    @Test func knowsWhichItemsExist() {
        engine.addItem(at: "/f", isDirectory: false)
        engine.mountVolume(at: "/Volumes/Disk")
        engine.addItem(at: "/Volumes/Disk/g")
        engine.unmountVolume(at: "/Volumes/Disk")

        #expect(engine.itemExists(atPath: "/f") == true)
        #expect(engine.itemExists(atPath: "/f/") == true)
        #expect(engine.itemExists(atPath: "/nothing") == false)
        #expect(engine.itemExists(atPath: "/Volumes/Disk/g") == false)
    }

    @Suite("Document keys")
    struct DocumentKeys {
        let base = FakeSandboxTests()
        var engine: FakeBookmarkEngine { base.engine }

        init() {
            base.engine.addItem(at: "/doc", isDirectory: false)
        }

        @Test func bookmarksOnOneDocumentShareItsKey() throws {
            let first = try base.bookmark("/a", document: "/doc")
            let second = try base.bookmark("/b", document: "/doc")

            #expect(base.code(resolving: first, document: "/doc") == nil)
            #expect(base.code(resolving: second, document: "/doc") == nil)
        }

        @Test func needAnAnchor() throws {
            let data = try base.bookmark("/a", document: "/doc")

            #expect(base.code(resolving: data) == NSFileReadCorruptFileError)
        }

        @Test func aPlainReplaceLosesTheKeyAndAKeepingOneDoesnt() throws {
            let data = try base.bookmark("/a", document: "/doc")

            engine.replaceItem(at: "/doc", keepingExtendedAttributes: true)
            let kept = base.code(resolving: data, document: "/doc")
            engine.replaceItem(at: "/doc")

            #expect(kept == nil)
            #expect(base.code(resolving: data, document: "/doc") == NSFileReadUnknownError)
        }

        @Test func strippingAttributesLosesTheKey() throws {
            let data = try base.bookmark("/a", document: "/doc")

            engine.stripExtendedAttributes(at: "/doc")
            engine.stripExtendedAttributes(at: "/nothing")

            #expect(base.code(resolving: data, document: "/doc") == NSFileReadUnknownError)
        }

        @Test func aMovedAnchorKeepsItsKey() throws {
            let data = try base.bookmark("/a", document: "/doc")

            engine.moveItem(from: "/doc", to: "/moved")

            #expect(base.code(resolving: data, document: "/moved") == nil)
        }

        @Test func aGoneAnchorIsMissing() throws {
            let data = try base.bookmark("/a", document: "/doc")

            engine.removeItem(at: "/doc")

            #expect(base.code(resolving: data, document: "/doc") == NSFileNoSuchFileError)
        }

        @Test func creationChecksTheAnchorAndTarget() {
            engine.addItem(at: "/folder")
            engine.makeAccessibleWithoutGrant("/folder")

            #expect(throws: CocoaError(.fileReadUnknown)) { try base.bookmark("/a", document: "/folder") }
            #expect(throws: CocoaError(.fileReadUnknown)) {
                try engine.makeBookmark(for: URL(filePath: "/folder"), options: [.scope], includingResourceValuesFor: [], relativeTo: URL(filePath: "/doc"))
            }
            #expect(throws: CocoaError(.fileReadNoSuchFile)) { try base.bookmark("/a", document: "/missing") }
        }

        @Test func replacingThroughTheEngineKeepsTheKey() throws {
            let data = try base.bookmark("/a", document: "/doc")

            try engine.replaceItem(at: URL(filePath: "/doc")) { url in try Data("x".utf8).write(to: url) }

            #expect(base.code(resolving: data, document: "/doc") == nil)
            #expect(engine.calls.replacements == 1)
        }

        @Test func replacingNothingFails() {
            #expect(throws: CocoaError(.fileNoSuchFile)) {
                try engine.replaceItem(at: URL(filePath: "/nothing")) { url in try Data("x".utf8).write(to: url) }
            }
        }
    }
}
