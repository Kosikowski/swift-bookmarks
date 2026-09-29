#if os(macOS)
@testable import Bookmarks
import Foundation
import Testing

/// Exercises the real Foundation APIs on temporary files. `swift test` isn't sandboxed, so
/// these tests cover bookmark creation, resolution, staleness and failures, not sandbox
/// denials.
@Suite("System engine")
struct SystemEngineTests {
    let sandbox = TemporaryDirectory()
    let service = BookmarkService(engine: SystemBookmarkEngine(), executor: BlockingExecutor(label: "system-tests", width: 4))

    func grant(_ url: URL) -> Grant {
        Grant(url: url, origin: .alreadyAccessible)
    }

    @Test func runsUnsandboxed() {
        #expect(!service.environment.isSandboxed)
        #expect(service.defaultKind == .reference)
    }

    @Test(arguments: [BookmarkKind.appScoped(.readWrite), .appScoped(.readOnly), .implicit, .reference, .alias])
    func createsAndResolvesEveryKind(_ kind: BookmarkKind) async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Folder")

        let data = try await service.create(for: grant(folder), kind: kind)
        let resolved = try await service.resolve(data, kind: kind)

        #expect(!resolved.wasStale)
        #expect(sandbox.canonical(resolved.url) == sandbox.canonical(folder))
    }

    @Test func leasesStartAccessOutsideTheSandbox() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Folder")
        let data = try await service.create(for: grant(folder), kind: .appScoped(.readWrite))

        let lease = try await service.resolve(data, kind: .appScoped(.readWrite)).beginAccess()
        defer { lease.end() }

        #expect(lease.didStartScope)
        #expect(FileManager.default.fileExists(atPath: lease.url.appending(path: ".").path(percentEncoded: false)))
    }

    @Test func renamesAreStaleAndRefreshed() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Before")
        let data = try await service.create(for: grant(folder), kind: .appScoped(.readWrite))
        let renamed = sandbox.url("After")
        try FileManager.default.moveItem(at: folder, to: renamed)

        let resolved = try await service.resolve(data, kind: .appScoped(.readWrite))

        #expect(resolved.wasStale)
        #expect(sandbox.canonical(resolved.url) == sandbox.canonical(renamed))
        let refreshed = try #require(resolved.refreshedData)
        #expect(try await !service.resolve(refreshed, kind: .appScoped(.readWrite)).wasStale)
    }

    @Test func renamingAParentMakesChildrenStale() async throws {
        defer { sandbox.remove() }
        let parent = try sandbox.makeDirectory("Parent")
        let child = try sandbox.makeDirectory("Parent/Child")
        let data = try await service.create(for: grant(child), kind: .reference)
        try FileManager.default.moveItem(at: parent, to: sandbox.url("Renamed"))

        let resolved = try await service.resolve(data, kind: .reference)

        #expect(resolved.wasStale)
        #expect(resolved.displayPath.hasSuffix("/Renamed/Child/"))
    }

    @Test func atomicSavesKeepTheBookmarkWorking() async throws {
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("Notes.md", contents: "one")
        let data = try await service.create(for: grant(file), kind: .appScoped(.readWrite))
        try Data("two".utf8).write(to: file, options: .atomic)

        let resolved = try await service.resolve(data, kind: .appScoped(.readWrite))

        #expect(sandbox.canonical(resolved.url) == sandbox.canonical(file))
    }

    @Test func deletedItemsAreMissing() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Gone")
        let data = try await service.create(for: grant(folder), kind: .appScoped(.readWrite))
        try FileManager.default.removeItem(at: folder)

        let error = await #expect(throws: BookmarkError.self) {
            try await service.resolve(data, kind: .appScoped(.readWrite))
        }

        #expect(error?.failure == .missing)
        #expect(error?.lastKnownPath?.hasSuffix("/Gone") == true)
    }

    @Test func availabilityReflectsTheFileSystem() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Folder")
        let data = try await service.create(for: grant(folder), kind: .reference)

        #expect(await service.availability(of: data, kind: .reference) == .available)
        try FileManager.default.removeItem(at: folder)
        #expect(await service.availability(of: data, kind: .reference) == .missing)
    }

    @Test func creatingABookmarkToNothingFails() async {
        defer { sandbox.remove() }

        let error = await #expect(throws: BookmarkError.self) {
            try await service.create(for: grant(sandbox.url("Nothing")), kind: .reference)
        }

        #expect(error?.failure == .missing)
    }

    @Test func garbageIsCorrupt() async {
        let error = await #expect(throws: BookmarkError.self) {
            try await service.resolve(BookmarkData(Data("not a bookmark".utf8)), kind: .appScoped(.readWrite))
        }

        #expect(error?.failure == .corrupt)
    }

    @Test func plainBookmarksResolvedWithScopeNeedARegrant() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Folder")
        let data = try await service.create(for: grant(folder), kind: .reference)

        let error = await #expect(throws: BookmarkError.self) {
            try await service.resolve(data, kind: .appScoped(.readWrite))
        }

        #expect(error?.failure == .needsRegrant)
    }

    @Test func documentScopeNeedsItsEntitlement() async throws {
        defer { sandbox.remove() }
        let document = try sandbox.makeFile("Doc.txt", contents: "doc")
        let image = try sandbox.makeFile("Image.png", contents: "png")

        let error = await #expect(throws: BookmarkError.self) {
            try await service.documents(anchoredOn: document).create(for: grant(image))
        }

        #expect(error?.failure == .denied)
    }

    @Test func recordedValuesSurviveDeletion() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Recorded")
        let data = try await service.create(for: grant(folder), kind: .appScoped(.readWrite))
        try FileManager.default.removeItem(at: folder)

        let recorded = try #require(service.recordedValues(in: data))

        #expect(recorded.name == "Recorded")
        #expect(recorded.path?.hasSuffix("/Recorded") == true)
        #expect(recorded.isDirectory == true)
        #expect(recorded.isOnBootVolume)
    }

    @Test func extraResourceValuesAreStored() async throws {
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("Sized.txt", contents: "12345")
        let plain = try await service.create(for: grant(file), kind: .reference)

        let withSize = try await service.create(for: grant(file), kind: .reference, includingResourceValuesFor: [.fileSizeKey])

        #expect(URL.resourceValues(forKeys: [.fileSizeKey], fromBookmarkData: withSize.rawValue)?.fileSize == 5)
        #expect(withSize.count > plain.count)
    }

    @Test func aliasFilesRoundTrip() async throws {
        defer { sandbox.remove() }
        let target = try sandbox.makeDirectory("Target")
        let alias = sandbox.url("Target alias")
        let aliases = service.aliasFiles

        try await aliases.write(aliasTo: grant(target), at: alias)
        let resolved = try await aliases.resolve(aliasAt: alias)

        #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        #expect(sandbox.canonical(resolved.url) == sandbox.canonical(target))
    }

    @Test func handoffTokensCarryAccessBetweenResolutions() async throws {
        defer { sandbox.remove() }
        let folder = try sandbox.makeDirectory("Shared")
        let data = try await service.create(for: grant(folder), kind: .appScoped(.readWrite))
        let lease = try await service.resolve(data, kind: .appScoped(.readWrite)).beginAccess()
        let handoff = service.handoff

        let token = try await handoff.makeToken(for: lease)
        lease.end()
        let received = try await handoff.receive(token)

        #expect(received.didStartScope)
        #expect(sandbox.canonical(received.url) == sandbox.canonical(folder))
        received.end()
    }

    @Suite("File inspection")
    struct Inspection {
        let sandbox = TemporaryDirectory()
        let engine = SystemBookmarkEngine()

        @Test func identitiesFollowRenamesAndChangeOnReplace() throws {
            defer { sandbox.remove() }
            let file = try sandbox.makeFile("A.txt", contents: "a")
            let original = try #require(engine.fileIdentity(of: file))
            let renamed = sandbox.url("B.txt")
            try FileManager.default.moveItem(at: file, to: renamed)

            #expect(engine.fileIdentity(of: renamed) == original)
            try Data("b".utf8).write(to: renamed, options: .atomic)
            #expect(engine.fileIdentity(of: renamed) != original)
            #expect(!original.volumeUUID.isEmpty)
        }

        @Test func describesItems() throws {
            defer { sandbox.remove() }
            let folder = try sandbox.makeDirectory("Folder")
            let link = sandbox.url("Link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

            let folderInfo = try #require(engine.itemInfo(at: folder))
            let linkInfo = try #require(engine.itemInfo(at: link))

            #expect(folderInfo.isDirectory && !folderInfo.isSymbolicLink)
            #expect(linkInfo.isSymbolicLink)
            // A link describes itself, not its target; the fake engine follows this.
            #expect(!linkInfo.isDirectory)
            #expect(linkInfo.canonicalPath == sandbox.canonical(folder))
            #expect(engine.itemInfo(at: sandbox.url("Nothing")) == nil)
            #expect(engine.fileIdentity(of: sandbox.url("Nothing")) == nil)
            #expect(engine.recordedValues(in: BookmarkData(Data("garbage".utf8))) == nil)
        }

        @Test func bookmarksOfALinkRecordTheLinkAndResolveToIt() async throws {
            defer { sandbox.remove() }
            let folder = try sandbox.makeDirectory("Folder")
            let link = sandbox.url("Link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            let service = BookmarkService(engine: engine, executor: BlockingExecutor(label: "system-tests.links", width: 1))

            let data = try await service.create(for: Grant(url: link, origin: .alreadyAccessible), kind: .reference)
            let resolved = try await service.resolve(data, kind: .reference)

            #expect(engine.recordedValues(in: data)?.path?.hasSuffix("/Link") == true)
            #expect(resolved.url.lastPathComponent == "Link")
        }

        @Test func overlapChecksSeeThroughStoredLinks() async throws {
            defer { sandbox.remove() }
            let folder = try sandbox.makeDirectory("Folder")
            let link = sandbox.url("Link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            let service = BookmarkService(engine: engine, executor: BlockingExecutor(label: "system-tests.overlap", width: 1))
            let context = ValidationContext(existingPaths: [link.path(percentEncoded: false)])

            let error = await #expect(throws: BookmarkError.self) {
                try await service.create(for: Grant(url: folder, origin: .alreadyAccessible), kind: .reference, validators: [.noOverlap], context: context)
            }

            guard case .refused(.duplicate) = error?.failure else {
                Issue.record("Expected a duplicate refusal, got \(String(describing: error))")
                return
            }
        }

        @Test func caseSensitivityComesFromTheNearestExistingItem() throws {
            defer { sandbox.remove() }
            let folder = try sandbox.makeDirectory("Folder")
            let values = try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            let expected = try #require(values.volumeSupportsCaseSensitiveNames as Bool?)

            #expect(engine.namesAreCaseSensitive(at: folder) == expected)
            #expect(engine.namesAreCaseSensitive(at: folder.appending(path: "Missing/Deeper")) == expected)
            #expect(try #require(engine.itemInfo(at: folder)).namesAreCaseSensitive == expected)
        }

        @Test func onlyVolumeRootsAreMountedVolumes() throws {
            defer { sandbox.remove() }
            let folder = try sandbox.makeDirectory("Folder")

            #expect(engine.isVolumeMounted(atPath: "/"))
            #expect(!engine.isVolumeMounted(atPath: folder.path(percentEncoded: false)))
            #expect(!engine.isVolumeMounted(atPath: sandbox.url("Nothing").path(percentEncoded: false)))
        }
    }
}

@Suite("System store")
struct SystemStoreTests {
    let sandbox = TemporaryDirectory()

    @Test func persistsRefreshedBookmarksAcrossStoreInstances() async throws {
        defer { sandbox.remove() }
        let service = BookmarkService(engine: SystemBookmarkEngine(), executor: BlockingExecutor(label: "system-store", width: 2))
        let file = sandbox.url("Store/bookmarks.json")
        let folder = try sandbox.makeDirectory("Project")
        let first = BookmarkStore<BookmarkID, NoMetadata>(
            persistence: JSONFilePersistence(fileURL: file),
            kind: .appScoped(.readWrite),
            service: service
        )
        let record = try await first.add(Grant(url: folder, origin: .alreadyAccessible))
        let moved = sandbox.url("Moved Project")
        try FileManager.default.moveItem(at: folder, to: moved)

        let second = BookmarkStore<BookmarkID, NoMetadata>(
            persistence: JSONFilePersistence(fileURL: file),
            kind: .appScoped(.readWrite),
            service: service
        )
        let path = try await second.withAccess(to: record.key) { sandbox.canonical($0) }
        let stored = try #require(try await second.record(record.key))

        #expect(path == sandbox.canonical(moved))
        #expect(stored.data != record.data)
        #expect(stored.lastKnownPath.hasSuffix("/Moved Project"))
        #expect(stored.fileIdentity == record.fileIdentity)
    }
}

#endif
