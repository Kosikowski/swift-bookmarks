#if os(macOS)
@testable import Bookmarks
import Foundation
import Testing

/// A disk image the tests create, attach and detach, standing in for an external disk.
struct DiskImage {
    let name = "BMTest-\(UUID().uuidString.prefix(8))"
    let folder = TemporaryDirectory()

    /// Whether this machine lets the tests create and attach disk images. Some CI machines
    /// don't, and the tests then don't run rather than fail.
    static let canAttach: Bool = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else { return false }
        let probe = DiskImage()
        defer { probe.destroy() }
        do {
            try probe.create()
            try probe.attach()
            try probe.detach()
            return true
        } catch {
            return false
        }
    }()

    var file: URL { folder.url("\(name).dmg") }
    var mountPoint: URL { URL(filePath: "/Volumes/\(name)", directoryHint: .isDirectory) }

    func create() throws {
        _ = try folder.makeDirectory(".")
        try Self.hdiutil("create", "-size", "8m", "-fs", "HFS+", "-volname", name, "-type", "UDIF", file.path(percentEncoded: false))
    }

    func attach() throws {
        try Self.hdiutil("attach", "-nobrowse", file.path(percentEncoded: false))
    }

    func detach() throws {
        try Self.hdiutil("detach", "-force", mountPoint.path(percentEncoded: false))
    }

    func destroy() {
        try? detach()
        folder.remove()
    }

    private static func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedFailureReasonErrorKey: "hdiutil \(arguments.first ?? "") failed"])
        }
    }
}

@Suite("System: volumes", .serialized, .enabled(if: DiskImage.canAttach), .timeLimit(.minutes(2)))
struct VolumeSystemTests {
    @Test func itemsOnADetachedDiskAreUnavailableNotGoneAndComeBack() async throws {
        let image = DiskImage()
        defer { image.destroy() }
        try image.create()
        try image.attach()
        let project = image.mountPoint.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let notes = image.mountPoint.appending(path: "Notes.txt")
        try Data("notes".utf8).write(to: notes)
        let service = BookmarkService(engine: SystemBookmarkEngine(), executor: BlockingExecutor(label: "volume-tests", width: 2), ledger: ScopeLedger())
        let store = BookmarkStore<String, NoMetadata>(persistence: InMemoryPersistence(), policy: StorePolicy(eviction: .goneFirst), service: service)
        try await store.add(Grant(url: project, origin: .alreadyAccessible), key: "project")
        try await store.add(pathOnly: notes, key: "notes")

        try image.detach()
        let error = await #expect(throws: BookmarkStoreError<String>.self) { try await store.lease("project") }
        let availability = try await store.availability("notes")

        #expect(error?.bookmarkFailure == .volumeUnavailable(name: image.name))
        #expect(store.snapshot["project"]?.isGone == false)
        #expect(availability == .volumeUnavailable(name: image.name))
        #expect(!FileManager.default.fileExists(atPath: image.mountPoint.path(percentEncoded: false)), "resolving didn't mount it")

        try image.attach()
        let recovered = try await store.refreshStatuses()

        #expect(Set(recovered) == ["project", "notes"])
        #expect(store.snapshot["project"]?.status == .available)
        #expect(store.snapshot["notes"]?.hasBookmark == true)
    }
}
#endif
