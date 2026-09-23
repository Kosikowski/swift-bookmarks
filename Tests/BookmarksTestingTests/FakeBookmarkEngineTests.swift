import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("FakeBookmarkEngine")
struct FakeBookmarkEngineTests {
    let engine = FakeBookmarkEngine()

    func bookmark(_ path: String, options: URL.BookmarkCreationOptions = [.withSecurityScope], origin: Grant.Origin = .openPanel) throws -> BookmarkData {
        engine.addItem(at: path)
        // The grant balances the system's start when it's released at the end of this call.
        let grant = engine.grant(path, origin: origin)
        return try engine.makeBookmark(for: grant.url, options: options, includingResourceValuesFor: [], relativeTo: nil)
    }

    @Suite("File system")
    struct FileSystem {
        let engine = FakeBookmarkEngine()

        @Test func aFolderIsGrantedAsADirectoryURL() {
            engine.addItem(at: "/Users/me/Folder")
            engine.addItem(at: "/Users/me/file.md", isDirectory: false)

            #expect(engine.grant("/Users/me/Folder", origin: .openPanel).url.hasDirectoryPath)
            #expect(!engine.grant("/Users/me/file.md", origin: .openPanel).url.hasDirectoryPath)
        }

        @Test func addingCreatesParents() {
            engine.addItem(at: "/a/b/c.txt", isDirectory: false)

            #expect(engine.containsItem(at: "/a"))
            #expect(engine.containsItem(at: "/a/b"))
            #expect(engine.itemInfo(at: URL(filePath: "/a/b"))?.isDirectory == true)
            #expect(engine.itemInfo(at: URL(filePath: "/a/b/c.txt"))?.isDirectory == false)
        }

        @Test func removingRemovesDescendants() {
            engine.addItem(at: "/a/b/c")
            engine.addItem(at: "/ab")

            engine.removeItem(at: "/a")

            #expect(!engine.containsItem(at: "/a/b/c"))
            #expect(engine.containsItem(at: "/ab"))
        }

        @Test func movesKeepIdentities() {
            engine.addItem(at: "/a/child")
            let identity = engine.fileIdentity(of: URL(filePath: "/a/child"))

            engine.moveItem(from: "/a", to: "/z/renamed")

            #expect(!engine.containsItem(at: "/a/child"))
            #expect(engine.fileIdentity(of: URL(filePath: "/z/renamed/child")) == identity)
        }

        @Test func replacingChangesTheIdentity() {
            engine.addItem(at: "/f", isDirectory: false)
            let identity = engine.fileIdentity(of: URL(filePath: "/f"))

            engine.replaceItem(at: "/f")
            engine.replaceItem(at: "/missing")

            #expect(engine.fileIdentity(of: URL(filePath: "/f")) != identity)
            #expect(!engine.containsItem(at: "/missing"))
        }

        @Test func unmountedVolumesHideTheirItems() {
            engine.mountVolume(at: "/Volumes/Disk")
            engine.addItem(at: "/Volumes/Disk/Folder")

            engine.unmountVolume(at: "/Volumes/Disk")

            #expect(!engine.containsItem(at: "/Volumes/Disk/Folder"))
            #expect(!engine.isVolumeMounted(atPath: "/Volumes/Disk"))
            #expect(engine.fileIdentity(of: URL(filePath: "/Volumes/Disk/Folder")) == nil)
            engine.mountVolume(at: "/Volumes/Disk")
            #expect(engine.containsItem(at: "/Volumes/Disk/Folder"))
            #expect(engine.isVolumeMounted(atPath: "/Volumes/Disk"))
        }

        @Test func movesAcrossVolumesChangeIdentity() {
            engine.mountVolume(at: "/Volumes/Backup")
            engine.addItem(at: "/Users/me/F")
            engine.addItem(at: "/Users/me/G")
            let before = engine.fileIdentity(of: URL(filePath: "/Users/me/F"))
            let sameVolume = engine.fileIdentity(of: URL(filePath: "/Users/me/G"))

            engine.moveItem(from: "/Users/me/F", to: "/Volumes/Backup/F")
            engine.moveItem(from: "/Users/me/G", to: "/Users/me/H")

            #expect(engine.fileIdentity(of: URL(filePath: "/Volumes/Backup/F"))?.fileID != before?.fileID)
            #expect(engine.fileIdentity(of: URL(filePath: "/Users/me/H")) == sameVolume)
        }

        @Test func bookmarksToItemsMovedToAnotherVolumeAreMissing() async throws {
            engine.mountVolume(at: "/Volumes/Backup")
            engine.addItem(at: "/Users/me/F")
            let grant = engine.grant("/Users/me/F", origin: .openPanel)
            let data = try engine.makeBookmark(for: grant.url, options: [.withSecurityScope], includingResourceValuesFor: [], relativeTo: nil)

            engine.moveItem(from: "/Users/me/F", to: "/Volumes/Backup/F")

            #expect(throws: CocoaError.self) { try engine.resolve(data, options: [], relativeTo: nil) }
        }

        @Test func symbolicLinksResolveToTheirTargets() {
            engine.addItem(at: "/real/inner")
            engine.addSymbolicLink(at: "/link", pointingTo: "/real")

            #expect(engine.itemInfo(at: URL(filePath: "/link"))?.isSymbolicLink == true)
            #expect(engine.itemInfo(at: URL(filePath: "/link"))?.isDirectory == false)
            #expect(engine.itemInfo(at: URL(filePath: "/link"))?.canonicalPath == "/real")
            #expect(engine.itemInfo(at: URL(filePath: "/nothing")) == nil)
        }

        @Test func identitiesNameTheVolume() {
            engine.addItem(at: "/f")

            #expect(engine.fileIdentity(of: URL(filePath: "/f"))?.volumeUUID == "/")
        }
    }

    @Suite("Creation")
    struct Creation {
        let base = FakeBookmarkEngineTests()

        @Test func needsAccessInTheSandbox() {
            base.engine.addItem(at: "/private")

            #expect(throws: CocoaError.self) {
                try base.engine.makeBookmark(for: URL(filePath: "/private"), options: [.withSecurityScope], includingResourceValuesFor: [], relativeTo: nil)
            }
        }

        @Test func accessToAnAncestorIsEnough() throws {
            base.engine.addItem(at: "/granted/inner")
            let grant = base.engine.grant("/granted", origin: .openPanel)
            defer { base.engine.stopAccessing(grant.url) }

            _ = try base.engine.makeBookmark(for: URL(filePath: "/granted/inner"), options: [], includingResourceValuesFor: [], relativeTo: nil)
        }

        @Test func unsandboxedCreationNeedsNoAccess() throws {
            let engine = FakeBookmarkEngine(environment: SandboxEnvironment(platform: .macOS, isSandboxed: false))
            engine.addItem(at: "/f")

            _ = try engine.makeBookmark(for: URL(filePath: "/f"), options: [], includingResourceValuesFor: [], relativeTo: nil)
        }

        @Test(arguments: [URL.BookmarkCreationOptions([.withSecurityScope, .minimalBookmark]), [.withSecurityScope, .suitableForBookmarkFile]])
        func rejectsInvalidCombinations(_ options: URL.BookmarkCreationOptions) {
            #expect(throws: CocoaError.self) { try base.bookmark("/f", options: options) }
        }

        @Test func scopedBookmarksAreUnavailableOnIOS() {
            let engine = FakeBookmarkEngine(environment: SandboxEnvironment(platform: .iOS, isSandboxed: true))
            engine.addItem(at: "/f")
            let grant = engine.grant("/f", origin: .documentPicker)
            _ = engine.startAccessing(grant.url)

            #expect(throws: CocoaError.self) {
                try engine.makeBookmark(for: grant.url, options: [.withSecurityScope], includingResourceValuesFor: [], relativeTo: nil)
            }
        }

        @Test func eachBookmarkIsUnique() throws {
            #expect(try base.bookmark("/f") != base.bookmark("/f"))
        }

        @Test func scriptedFailuresRunOutAfterTheirCount() throws {
            base.engine.failCreation(of: "/f", with: FakeErrors.denied, times: 2)

            #expect(throws: NSError.self) { try base.bookmark("/f") }
            #expect(throws: NSError.self) { try base.bookmark("/f") }
            _ = try base.bookmark("/f")
        }

        @Test func recordsRequests() throws {
            _ = try base.bookmark("/f", options: [.withoutImplicitSecurityScope])

            #expect(base.engine.creationRequests.last?.options == [.withoutImplicitSecurityScope])
            #expect(base.engine.creationRequests.last?.path == "/f")
            #expect(base.engine.calls.creations == 1)
        }
    }

    @Suite("Resolution")
    struct Resolution {
        let base = FakeBookmarkEngineTests()

        @Test func resolvesToTheCurrentPath() throws {
            let data = try base.bookmark("/f")

            let (url, stale) = try base.engine.resolve(data, options: [.withSecurityScope], relativeTo: nil)

            #expect(url.path(percentEncoded: false) == "/f/")
            #expect(!stale)
        }

        @Test func forcedStalenessIsConsumed() throws {
            let data = try base.bookmark("/f")
            base.engine.reportStale("/f")

            #expect(try base.engine.resolve(data, options: [.withSecurityScope], relativeTo: nil).isStale)
            #expect(try !base.engine.resolve(data, options: [.withSecurityScope], relativeTo: nil).isStale)
        }

        @Test func scopedOptionsOnPlainBookmarksAreRejected() throws {
            let data = try base.bookmark("/f", options: [])

            #expect(throws: CocoaError.self) { try base.engine.resolve(data, options: [.withSecurityScope], relativeTo: nil) }
        }

        @Test func implicitBookmarksStartAccessUnlessTold() throws {
            let data = try base.bookmark("/f", options: [])

            _ = try base.engine.resolve(data, options: [.withoutImplicitStartAccessing], relativeTo: nil)
            #expect(!base.engine.isAccessing("/f"))

            let (url, _) = try base.engine.resolve(data, options: [], relativeTo: nil)
            #expect(base.engine.isAccessing("/f"))
            base.engine.stopAccessing(url)
            #expect(base.engine.isBalanced)
        }

        @Test func gatesHoldResolutionUntilOpened() async throws {
            let data = try base.bookmark("/f")
            let gate = base.engine.holdResolution(of: "/f")
            let engine = base.engine

            let task = Task.detached { try engine.resolve(data, options: [.withSecurityScope], relativeTo: nil) }
            await gate.waitUntilReached()
            gate.open()

            #expect(try await task.value.url.path(percentEncoded: false) == "/f/")
        }

        @Test func recordedValuesDescribeTheBookmark() throws {
            base.engine.mountVolume(at: "/Volumes/Disk")
            let onVolume = try base.bookmark("/Volumes/Disk/f")
            let onBoot = try base.bookmark("/g")

            #expect(base.engine.recordedValues(in: onVolume) == RecordedValues(path: "/Volumes/Disk/f", name: "f", volumePath: "/Volumes/Disk", volumeName: "Disk", isDirectory: true))
            #expect(base.engine.recordedValues(in: onBoot)?.volumeName == "Macintosh HD")
            #expect(base.engine.recordedValues(in: BookmarkData(Data())) == nil)
        }
    }

    @Suite("Access accounting")
    struct Accounting {
        let base = FakeBookmarkEngineTests()

        @Test func systemStartedGrantsCountAsOutstanding() {
            base.engine.addItem(at: "/f")

            let grant = base.engine.grant("/f", origin: .appKitDrop)

            #expect(base.engine.outstandingAccess == ["/f": 1])
            base.engine.stopAccessing(grant.url)
            #expect(base.engine.isBalanced)
        }

        @Test func importerGrantsAreNotStarted() {
            base.engine.addItem(at: "/f")

            _ = base.engine.grant("/f", origin: .fileImporter)

            #expect(base.engine.outstandingAccess.isEmpty)
        }

        @Test func extraStopsAreReported() {
            base.engine.addItem(at: "/f")
            let grant = base.engine.grant("/f", origin: .fileImporter)

            base.engine.stopAccessing(grant.url)

            #expect(base.engine.unbalancedStops == ["/f"])
            #expect(!base.engine.isBalanced)
        }

        @Test func startsOnUnissuedURLsAreReported() {
            #expect(!base.engine.startAccessing(URL(filePath: "/rebuilt")))
            #expect(base.engine.startsOnUnissuedURLs == ["/rebuilt"])
        }

        @Test func unsandboxedStartsOnUnissuedURLsReturnFalse() {
            let engine = FakeBookmarkEngine(environment: SandboxEnvironment(platform: .macOS, isSandboxed: false))

            #expect(!engine.startAccessing(URL(filePath: "/anything")))
            #expect(engine.startsOnUnissuedURLs == ["/anything"])
            #expect(engine.isBalanced)
        }

        @Test func refusedStartsReturnFalse() {
            base.engine.addItem(at: "/f")
            let grant = base.engine.grant("/f", origin: .fileImporter)
            base.engine.refuseAccess(to: "/f")

            #expect(!base.engine.startAccessing(grant.url))
            #expect(base.engine.calls.starts == 1)
        }

        @Test func freelyAccessibleLocationsNeedNoGrant() throws {
            base.engine.addItem(at: "/Container/Data")
            base.engine.makeAccessibleWithoutGrant("/Container")

            _ = try base.engine.makeBookmark(for: URL(filePath: "/Container/Data"), options: [], includingResourceValuesFor: [], relativeTo: nil)
        }
    }

    @Suite("Alias files")
    struct Aliases {
        let base = FakeBookmarkEngineTests()

        @Test func onlyAliasBookmarksCanBeWritten() throws {
            let plain = try base.bookmark("/f", options: [])
            let alias = try base.bookmark("/g", options: [.suitableForBookmarkFile])

            #expect(throws: CocoaError.self) { try base.engine.writeAliasFile(plain, to: URL(filePath: "/alias")) }
            try base.engine.writeAliasFile(alias, to: URL(filePath: "/alias"))
            #expect(try base.engine.aliasFileData(at: URL(filePath: "/alias")) == alias)
        }

        @Test func readingAMissingAliasFails() {
            #expect(throws: CocoaError.self) { try base.engine.aliasFileData(at: URL(filePath: "/none")) }
        }
    }

    @Test func errorsMatchTheSystemCodes() {
        #expect(FakeErrors.noSuchFile.code == NSFileNoSuchFileError)
        #expect(FakeErrors.corrupt.code == NSFileReadCorruptFileError)
        #expect(FakeErrors.denied.code == NSFileReadUnknownError)
        #expect(FakeErrors.notPermitted.domain == NSPOSIXErrorDomain)
        #expect(FakeErrors.unexpected.domain == "FakeBookmarkEngine")
    }
}
