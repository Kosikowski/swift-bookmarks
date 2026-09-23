@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("Bookmarks: resolve")
struct ResolveTests {
    let engine = Fixtures.engine()
    var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

    @Test func resolvesAFreshBookmark() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)

        let resolved = try await bookmarks.resolve(data)

        #expect(!resolved.wasStale)
        #expect(resolved.refreshedData == nil)
        #expect(resolved.refreshError == nil)
        #expect(resolved.data == data)
        #expect(resolved.originalData == data)
        #expect(resolved.displayPath == "/Users/me/Folder/")
    }

    @Test func resolutionNeverMountsOrShowsUIByDefault() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)

        _ = try await bookmarks.resolve(data)

        let options = try #require(engine.resolutionRequests.last?.options)
        #expect(options.contains(.withoutMounting))
        #expect(options.contains(.withoutUI))
        #expect(options.contains(.withSecurityScope))
    }

    @Test func resolvingDoesNotStartAccess() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        let startsBefore = engine.calls.starts

        _ = try await bookmarks.resolve(data)

        #expect(engine.calls.starts == startsBefore)
        #expect(engine.isBalanced)
    }

    @Suite("Stale bookmarks")
    struct Stale {
        let engine = Fixtures.engine()
        var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

        @Test func refreshesAfterAMoveInsideTheScope() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            engine.moveItem(from: "/Users/me/Folder", to: "/Users/me/Renamed")

            let resolved = try await bookmarks.resolve(data)

            #expect(resolved.wasStale)
            #expect(resolved.needsPersisting)
            #expect(resolved.refreshError == nil)
            #expect(resolved.displayPath == "/Users/me/Renamed/")
            let refreshed = try #require(resolved.refreshedData)
            #expect(resolved.data == refreshed)
            #expect(engine.isBalanced)

            let again = try await bookmarks.resolve(refreshed)
            #expect(!again.wasStale)
            #expect(again.displayPath == "/Users/me/Renamed/")
        }

        @Test func refreshesAfterAnAtomicReplace() async throws {
            engine.addItem(at: "/Users/me/Notes.md", isDirectory: false)
            let data = try await bookmarks.adopt(engine.grant("/Users/me/Notes.md", origin: .openPanel)).data
            engine.replaceItem(at: "/Users/me/Notes.md")

            let resolved = try await bookmarks.resolve(data)

            #expect(resolved.wasStale)
            #expect(resolved.refreshedData != nil)
        }

        @Test func reportsAFailedRefreshButStillResolves() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            engine.reportStale("/Users/me/Folder")
            engine.failCreation(of: "/Users/me/Folder", with: FakeErrors.denied)

            let resolved = try await bookmarks.resolve(data)

            #expect(resolved.wasStale)
            #expect(resolved.refreshedData == nil)
            #expect(resolved.refreshError?.failure == .denied)
            #expect(resolved.data == data)
            #expect(!resolved.needsPersisting)
            #expect(engine.isBalanced)
        }

        @Test func refreshNeedsTheScopeToSucceed() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            engine.reportStale("/Users/me/Folder")
            engine.refuseAccess(to: "/Users/me/Folder")

            let resolved = try await bookmarks.resolve(data)

            #expect(resolved.refreshError?.failure == .denied)
            #expect(engine.isBalanced)
        }

        @Test func referenceBookmarksRefreshWithoutAScope() async throws {
            let engine = Fixtures.engine(Fixtures.unsandboxedMac)
            let bookmarks = Fixtures.bookmarks(engine)
            engine.addItem(at: "/Users/me/Folder")
            let data = try await bookmarks.adopt(engine.grant("/Users/me/Folder", origin: .alreadyAccessible), kind: .reference).data
            engine.moveItem(from: "/Users/me/Folder", to: "/Users/me/Moved")

            let resolved = try await bookmarks.resolve(data, kind: .reference)

            #expect(resolved.refreshedData != nil)
            #expect(engine.calls.starts == 0)
        }
    }

    @Suite("Failures")
    struct Failures {
        let engine = Fixtures.engine()
        var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

        @Test func deletedItemsAreMissing() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            engine.removeItem(at: "/Users/me/Folder")

            let error = await #expect(throws: BookmarkError.self) { try await bookmarks.resolve(data) }

            #expect(error?.failure == .missing)
            #expect(error?.lastKnownPath == "/Users/me/Folder")
        }

        @Test func movedAndReplacedItemsAreMissing() async throws {
            engine.addItem(at: "/Users/me/Notes.md", isDirectory: false)
            let data = try await bookmarks.adopt(engine.grant("/Users/me/Notes.md", origin: .openPanel)).data
            engine.moveItem(from: "/Users/me/Notes.md", to: "/Users/me/Moved.md")
            engine.replaceItem(at: "/Users/me/Moved.md")

            let error = await #expect(throws: BookmarkError.self) { try await bookmarks.resolve(data) }

            #expect(error?.failure == .missing)
        }

        @Test func unmountedVolumesAreNotMissing() async throws {
            engine.mountVolume(at: "/Volumes/Backup")
            let data = try await Fixtures.adoptFolder("/Volumes/Backup/Builds", engine: engine)
            engine.unmountVolume(at: "/Volumes/Backup")

            let error = await #expect(throws: BookmarkError.self) { try await bookmarks.resolve(data) }

            #expect(error?.failure == .volumeUnavailable(name: "Backup"))
            #expect(error?.failure.isTransient == true)
        }

        @Test func mountingCanBeAllowed() async throws {
            engine.mountVolume(at: "/Volumes/Backup")
            let data = try await Fixtures.adoptFolder("/Volumes/Backup/Builds", engine: engine)
            engine.unmountVolume(at: "/Volumes/Backup")

            let resolved = try await bookmarks.resolve(data, policy: .allowingMount)

            #expect(resolved.displayPath == "/Volumes/Backup/Builds/")
            #expect(engine.containsItem(at: "/Volumes/Backup/Builds"))
        }

        @Test func garbageBytesAreCorrupt() async {
            let error = await #expect(throws: BookmarkError.self) {
                try await bookmarks.resolve(BookmarkData(Data("garbage".utf8)))
            }

            #expect(error?.failure == .corrupt)
            #expect(error?.lastKnownPath == nil)
        }

        @Test func plainBookmarksResolvedAsScopedNeedARegrant() async throws {
            let engine = Fixtures.engine(Fixtures.unsandboxedMac)
            engine.addItem(at: "/Users/me/Folder")
            let data = try await Fixtures.bookmarks(engine).create(for: engine.grant("/Users/me/Folder", origin: .alreadyAccessible), kind: .reference)

            let error = await #expect(throws: BookmarkError.self) {
                try await Fixtures.bookmarks(engine).resolve(data, kind: .appScoped(.readWrite))
            }

            #expect(error?.failure == .needsRegrant)
        }

        @Test func scriptedErrorsAreClassified() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            engine.failResolution(of: "/Users/me/Folder", with: FakeErrors.unexpected)

            let error = await #expect(throws: BookmarkError.self) { try await bookmarks.resolve(data) }

            #expect(error?.failure == .other(domain: "FakeBookmarkEngine", code: 42))
            #expect((error?.underlying as? NSError)?.code == 42)
        }

        @Test func transientFailuresRecover() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            engine.failResolution(of: "/Users/me/Folder", with: FakeErrors.denied, times: 1)

            await #expect(throws: BookmarkError.self) { try await bookmarks.resolve(data) }
            _ = try await bookmarks.resolve(data)
        }

        @Test func slowResolutionsTimeOut() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            let gate = engine.holdResolution(of: "/Users/me/Folder")

            let error = await #expect(throws: BookmarkError.self) {
                try await Fixtures.bookmarks(engine, timeout: .milliseconds(30)).resolve(data)
            }

            #expect(error?.failure == .timedOut)
            gate.open()
        }

        @Test func cancelledCallersStopWaiting() async throws {
            let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
            let gate = engine.holdResolution(of: "/Users/me/Folder")
            let bookmarks = bookmarks

            let task = Task { try await bookmarks.resolve(data) }
            await gate.waitUntilReached()
            task.cancel()

            let error = await #expect(throws: BookmarkError.self) { try await task.value }
            #expect(error?.failure == .cancelled)
            gate.open()
        }
    }

    @Suite("Implicit bookmarks")
    struct Implicit {
        let engine = Fixtures.engine(Fixtures.iOS)
        var bookmarks: Bookmarks { Fixtures.bookmarks(engine) }

        func implicitBookmark() async throws -> BookmarkData {
            engine.addItem(at: "/Documents/Folder")
            return try await bookmarks.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))
        }

        @Test func doNotStartAccessUnlessAsked() async throws {
            let data = try await implicitBookmark()

            let resolved = try await bookmarks.resolve(data)

            #expect(engine.resolutionRequests.last?.options.contains(.withoutImplicitStartAccessing) == true)
            #expect(engine.isBalanced)
            let lease = resolved.beginAccess()
            #expect(engine.isAccessing("/Documents/Folder"))
            lease.end()
            #expect(engine.isBalanced)
        }

        @Test func implicitStartIsOwnedByTheFirstLease() async throws {
            let data = try await implicitBookmark()

            let resolved = try await bookmarks.resolve(data, policy: ResolutionPolicy(startsImplicitAccess: true))
            let startsAfterResolve = engine.calls.starts
            let lease = resolved.beginAccess()

            #expect(engine.calls.starts == startsAfterResolve)
            lease.end()
            #expect(engine.isBalanced)
        }
    }
}
