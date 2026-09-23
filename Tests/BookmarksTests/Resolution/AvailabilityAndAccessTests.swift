@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkService: availability")
struct AvailabilityCheckTests {
    let engine = Fixtures.engine()
    var service: BookmarkService { Fixtures.service(engine) }

    @Test func availableItems() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)

        #expect(await service.availability(of: data) == .available)
    }

    @Test func staleItemsAreStillAvailable() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        engine.moveItem(from: "/Users/me/Folder", to: "/Users/me/Moved")

        #expect(await service.availability(of: data) == .available)
    }

    @Test func missingItems() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        engine.removeItem(at: "/Users/me/Folder")

        #expect(await service.availability(of: data) == .missing)
    }

    @Test func unmountedVolumesAreNotMountedByTheCheck() async throws {
        engine.mountVolume(at: "/Volumes/Backup")
        let data = try await Fixtures.adoptFolder("/Volumes/Backup/Folder", engine: engine)
        engine.unmountVolume(at: "/Volumes/Backup")

        #expect(await service.availability(of: data) == .volumeUnavailable(name: "Backup"))
        #expect(!engine.containsItem(at: "/Volumes/Backup/Folder"))
    }

    @Test func rejectedBookmarksNeedARegrant() async {
        engine.addItem(at: "/Users/me/Folder")
        engine.failResolution(of: "/Users/me/Folder", with: FakeErrors.corrupt)
        let data = BookmarkData(Data("garbage".utf8))

        #expect(await service.availability(of: data) == .needsRegrant)
    }

    @Test func unsupportedKindsAreUnknown() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)

        #expect(await service.availability(of: data, kind: .documentScoped(.readWrite)) == .unknown)
    }

    @Test func checkingNeverStartsAccessOrRefreshes() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        engine.moveItem(from: "/Users/me/Folder", to: "/Users/me/Moved")
        let before = engine.calls

        _ = await service.availability(of: data)

        #expect(engine.calls.starts == before.starts)
        #expect(engine.calls.creations == before.creations)
    }

    @Test func implicitChecksNeverStartAccess() async throws {
        let engine = Fixtures.engine(Fixtures.iOS)
        engine.addItem(at: "/Documents/Folder")
        let service = Fixtures.service(engine)
        let data = try await service.create(for: engine.grant("/Documents/Folder", origin: .documentPicker))
        let starts = engine.calls.starts

        #expect(await service.availability(of: data) == .available)

        #expect(engine.calls.starts == starts)
        #expect(engine.resolutionRequests.last?.options.contains(.withoutImplicitStartAccessing) == true)
        #expect(engine.isBalanced)
    }

    @Test func recordedValuesComeFromTheBytes() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        engine.removeItem(at: "/Users/me/Folder")

        let recorded = service.recordedValues(in: data)

        #expect(recorded?.path == "/Users/me/Folder")
        #expect(recorded?.name == "Folder")
        #expect(recorded?.isDirectory == true)
    }
}

@Suite("BookmarkService: withAccess")
struct WithAccessTests {
    struct Failure: Error {}

    let engine = Fixtures.engine()
    var service: BookmarkService { Fixtures.service(engine) }

    @Test func holdsAccessWhileTheBodyRuns() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        let engine = engine

        let path = try await service.withAccess(to: data) { url in
            #expect(engine.isAccessing("/Users/me/Folder"))
            return url.path(percentEncoded: false)
        }

        #expect(path == "/Users/me/Folder/")
        #expect(engine.isBalanced)
    }

    @Test func endsAccessWhenTheBodyThrows() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)

        await #expect(throws: Failure.self) {
            try await service.withAccess(to: data) { _ in throw Failure() }
        }

        #expect(engine.isBalanced)
    }

    @Test func propagatesResolutionFailures() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        engine.removeItem(at: "/Users/me/Folder")

        let error = await #expect(throws: BookmarkError.self) {
            try await service.withAccess(to: data) { _ in }
        }

        #expect(error?.failure == .missing)
    }

    @Test @MainActor func runsTheBodyOnTheCallersActor() async throws {
        let data = try await Fixtures.adoptFolder("/Users/me/Folder", engine: engine)
        var touched = false

        try await service.withAccess(to: data) { _ in
            MainActor.assertIsolated()
            touched = true
        }

        #expect(touched)
    }
}
